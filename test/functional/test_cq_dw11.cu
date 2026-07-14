// Phase 6 阶段 2 — Create-CQ 命令 DWORD11 位域单元测试
//
// 验证 nvm_cq_dw11() 按 NVMe Base Spec 正确构造 Create I/O Completion Queue
// 命令的 DWORD11：
//   bit 0      PC  (Physically Contiguous)
//   bit 1      IEN (Interrupts Enabled)
//   bits 31:16 IV  (Interrupt Vector)
//
// 这是纯逻辑单元测试，不涉及设备或 GPU（忽略命令行参数）。
//
// RED：nvm_cq_dw11() 尚不存在时编译失败。
// GREEN：在 nvm_cmd.h 实现后，全部断言通过。

#include <cstdio>
#include <cstdint>
#include <libnvm/nvm_cmd.h>

static int failures = 0;

#define CHECK_EQ(actual, expected, desc)                                   \
    do {                                                                    \
        uint32_t _a = (actual), _e = (expected);                            \
        if (_a != _e) {                                                     \
            printf("  FAIL: %s: expected 0x%08x, got 0x%08x\n",             \
                   desc, _e, _a);                                           \
            failures++;                                                     \
        }                                                                   \
    } while (0)

int main(int, char**) {
    // 1. 默认：无中断，物理连续 (PC=1) —— 与旧代码 (!need_prp) 一致
    //    need_prp=false ⇒ PC=1；iv=0, ien=false
    CHECK_EQ(nvm_cq_dw11(0, false, /*prp_contiguous=*/true),
             0x00000001u, "PC only (contiguous, no IRQ)");

    // 2. 非连续 (PC=0)，无中断
    CHECK_EQ(nvm_cq_dw11(0, false, /*prp_contiguous=*/false),
             0x00000000u, "non-contiguous, no IRQ");

    // 3. 中断使能，向量 0，物理连续 ⇒ IEN(bit1)=1, PC(bit0)=1
    CHECK_EQ(nvm_cq_dw11(0, true, /*prp_contiguous=*/true),
             0x00000003u, "IEN + PC, vector 0");

    // 4. 中断使能，向量 5，物理连续 ⇒ IV=5<<16 | IEN | PC
    CHECK_EQ(nvm_cq_dw11(5, true, /*prp_contiguous=*/true),
             (5u << 16) | 0x3u, "IEN + PC, vector 5");

    // 5. 中断使能，向量 16（本盘最大 17 个向量的边界内）
    CHECK_EQ(nvm_cq_dw11(16, true, /*prp_contiguous=*/true),
             (16u << 16) | 0x3u, "IEN + PC, vector 16");

    // 6. 向量非零但 IEN=false ⇒ IV 仍写入，IEN 位为 0
    //    (控制器在 IEN=0 时忽略 IV，但位域构造应如实反映参数)
    CHECK_EQ(nvm_cq_dw11(5, false, /*prp_contiguous=*/true),
             (5u << 16) | 0x1u, "IV set but IEN=0");

    if (failures == 0) {
        printf("PASS\n");
        return 0;
    }
    printf("FAIL: %d bitfield mismatch(es)\n", failures);
    return 1;
}
