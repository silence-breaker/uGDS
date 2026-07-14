// Phase 6 Stage 4 - End-to-end test for interrupt mode
//
// Forces UGDS_INTERRUPT_MODE and verifies that I/O is still correct in
// interrupt mode (the user thread blocks on an eventfd waiting for the MSI-X
// interrupt instead of busy-polling):
//   1. single 4KB write / clear / read-back / verify
//   2. 8 consecutive 4KB I/Os -- exercises completion coalescing (several
//      completions may raise only one eventfd signal, so wait_for_completion
//      must re-poll the CQ each call to drain them all)
//
// Real-hardware signal: after running this, `cat /proc/interrupts | grep ugds`
// counts should be non-zero, proving the MSI-X interrupt actually fired (rather
// than silently falling back to polling).
//
// Note: setenv must happen before uGDSDriverOpen / handle creation, because
// interrupt mode is decided when uGDSHandleRegister creates the CQs.

#include "test_utils.h"

int main(int argc, char** argv) {
    if (!parse_args(argc, argv)) return 1;
    cudaSetDevice(g_gpu_id);

    // Force interrupt mode (must be set before creating the handle)
    setenv("UGDS_INTERRUPT_MODE", "1", 1);

    uGDSError_t st = uGDSDriverOpen();
    ASSERT_OK(st, "DriverOpen");

    uGDSHandle_t fh = open_handle();
    if (!fh) TEST_FAIL("open_handle failed (interrupt mode)");

    const size_t alloc_size = 65536;
    const size_t io_size = 4096;
    const uint32_t pattern = 0xABCD1234;

    void* d_buf = nullptr;
    cudaMalloc(&d_buf, alloc_size);
    if (!d_buf) TEST_FAIL("cudaMalloc failed");

    st = uGDSBufRegister(d_buf, alloc_size, TEST_BUF_FLAGS);
    ASSERT_OK(st, "BufRegister");

    // 1. Single 4KB write / clear / read-back / verify
    size_t n_words = io_size / sizeof(uint32_t);
    fill_pattern_u32<<<(n_words + 255) / 256, 256>>>((uint32_t*)d_buf, pattern, n_words);
    cudaDeviceSynchronize();

    ssize_t ret = uGDSWrite(fh, d_buf, io_size, 0, 0);
    if (ret < 0 || (size_t)ret != io_size)
        TEST_FAIL("interrupt-mode write: %zd / %zu", ret, io_size);

    cudaMemset(d_buf, 0, alloc_size);
    cudaDeviceSynchronize();

    ret = uGDSRead(fh, d_buf, io_size, 0, 0);
    if (ret < 0 || (size_t)ret != io_size)
        TEST_FAIL("interrupt-mode read: %zd / %zu", ret, io_size);

    uint32_t* h_buf = (uint32_t*)malloc(io_size);
    cudaMemcpy(h_buf, d_buf, io_size, cudaMemcpyDeviceToHost);
    for (size_t i = 0; i < n_words; i++) {
        if (h_buf[i] != pattern) {
            free(h_buf);
            TEST_FAIL("single-IO mismatch at word %zu: 0x%08X != 0x%08X",
                      i, h_buf[i], pattern);
        }
    }
    free(h_buf);

    // 2. 8x4KB burst (exercises completion coalescing)
    // Write 8 distinct patterns to 8 consecutive 4KB blocks, then read back and verify each.
    const int N = 8;
    for (int b = 0; b < N; b++) {
        uint32_t pat = 0x1000 + b;
        fill_pattern_u32<<<(n_words + 255) / 256, 256>>>((uint32_t*)d_buf, pat, n_words);
        cudaDeviceSynchronize();
        ret = uGDSWrite(fh, d_buf, io_size, (off_t)b * io_size, 0);
        if (ret < 0 || (size_t)ret != io_size)
            TEST_FAIL("burst write block %d: %zd", b, ret);
    }
    for (int b = 0; b < N; b++) {
        uint32_t pat = 0x1000 + b;
        cudaMemset(d_buf, 0, alloc_size);
        cudaDeviceSynchronize();
        ret = uGDSRead(fh, d_buf, io_size, (off_t)b * io_size, 0);
        if (ret < 0 || (size_t)ret != io_size)
            TEST_FAIL("burst read block %d: %zd", b, ret);
        uint32_t* hb = (uint32_t*)malloc(io_size);
        cudaMemcpy(hb, d_buf, io_size, cudaMemcpyDeviceToHost);
        for (size_t i = 0; i < n_words; i++) {
            if (hb[i] != pat) {
                free(hb);
                TEST_FAIL("burst block %d mismatch at word %zu: 0x%08X != 0x%08X",
                          b, i, hb[i], pat);
            }
        }
        free(hb);
    }

    uGDSBufDeregister(d_buf);
    cudaFree(d_buf);
    close_handle(fh);
    uGDSDriverClose();
    TEST_PASS();
}
