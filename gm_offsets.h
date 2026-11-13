/* 占位头文件：跑 python tools\gen_gm_offsets.py <script.json> 后自动覆盖为真实 RVA */
#ifndef GM_OFFSETS_H
#define GM_OFFSETS_H
#include <stdint.h>
#include <string.h>

static inline uint64_t GMOffsetFor(const char *name) {
    if (!name) return 0;
    return 0;   /* 未生成偏移时全部返回 0，dylib 会走 IL2CPP 反射模式 */
}

#endif /* GM_OFFSETS_H */
