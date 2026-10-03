#ifndef CODEX_TOKEN_BAR_CZSTD_H
#define CODEX_TOKEN_BAR_CZSTD_H

/* Expose ZSTD_FrameHeader and ZSTD_getFrameHeader to Swift callers. */
#define ZSTD_STATIC_LINKING_ONLY
#include "zstd.h"
#include "zstd_errors.h"

#endif /* CODEX_TOKEN_BAR_CZSTD_H */
