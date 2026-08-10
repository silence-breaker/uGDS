#include "test_utils.h"

#include <cerrno>

/* Built only with -DUGDS_TEST_FORCE_SQ_FULL_TIMEOUT=ON. The injected timeout
 * models an SQ-full wait for an older command. A safe timeout must preserve
 * the registered mapping and poison the handle until controller recovery. */
int main(int argc, char** argv) {
    if (!parse_args(argc, argv)) return 1;
    cudaSetDevice(g_gpu_id);

    uGDSError_t st = uGDSDriverOpen();
    ASSERT_OK(st, "DriverOpen");

    uGDSHandle_t fh = open_handle();
    if (!fh) TEST_FAIL("open_handle failed");

    void* d_buf = nullptr;
    cudaMalloc(&d_buf, 65536);
    if (!d_buf) TEST_FAIL("cudaMalloc failed");
    st = uGDSBufRegister(d_buf, 65536, TEST_BUF_FLAGS);
    ASSERT_OK(st, "BufRegister");

    ssize_t io_rc = uGDSRead(fh, d_buf, 4096, 0, 0);
    if (io_rc != -EIO)
        TEST_FAIL("uGDSRead: expected -EIO, got %zd", io_rc);

    st = uGDSHandleDeregisterEx(fh, 0);
    ASSERT_ERR(st, UGDS_BUSY, "HandleDeregisterEx after SQ-full timeout");
    st = uGDSBufDeregister(d_buf);
    ASSERT_ERR(st, UGDS_BUSY, "BufDeregister after SQ-full timeout");
    st = uGDSDriverClose();
    ASSERT_ERR(st, UGDS_BUSY, "DriverClose after SQ-full timeout");

    /* The process exit owns final cleanup; do not free a mapping that the
     * modelled outstanding command may still access. */
    TEST_PASS();
}
