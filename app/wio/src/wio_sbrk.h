// STACK_RESERVE (wio_sbrk.cxx): the heap growths that stopped short of the
// stack, for the firmware's log.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  uint32_t refusals;   // growths refused since boot
  uint32_t last_incr;  // the last refused request, in bytes
  uintptr_t last_top;  // the heap's top when it was refused
  uintptr_t floor;     // the lowest stack pointer a growth was asked from
} WioSbrkStats;

const WioSbrkStats* wio_sbrk_stats(void);

// A "[Wio] heap: ..." line (no newline) on the refusals into buf, or 0 and
// nothing when there were none.
int wio_sbrk_describe(char* buf, size_t len);

#ifdef __cplusplus
}
#endif
