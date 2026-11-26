// STACK_RESERVE: the heap and the main stack share the RAM between __end__ and
// __StackTop, and the core's _sbrk only stops the break at the current stack
// pointer, so the next deeper call or interrupt writes over the newest block.
// Linked with --wrap=_sbrk (platformio.ini), this keeps WIO_STACK_RESERVE bytes
// free below the lowest stack pointer any growth was asked from (and below
// __StackLimit, when the link reserves a stack) and fails the growth with
// ENOMEM instead: malloc returns NULL, mruby collects and retries, then raises
// NoMemoryError. It must not call malloc or stdio itself.

#include "wio_sbrk.h"

#include <errno.h>

#include <cstdio>

#ifndef WIO_STACK_RESERVE
#error "WIO_STACK_RESERVE comes from platformio.ini's env:wio build_flags"
#endif

extern "C" char __StackLimit;

namespace {

WioSbrkStats g_stats;

}  // namespace

extern "C" {

void* __real__sbrk(ptrdiff_t incr);

void* __wrap__sbrk(ptrdiff_t incr) {
  // An interrupt's malloc between the check and the move would see a stale top.
  uint32_t primask;
  __asm__ volatile("mrs %0, primask\n\tcpsid i" : "=r"(primask)::"memory");
  uintptr_t sp;
  __asm__ volatile("mov %0, sp" : "=r"(sp));
  uintptr_t floor = g_stats.floor;
  if (!floor) {
    const uintptr_t limit = reinterpret_cast<uintptr_t>(&__StackLimit);
    floor = limit < sp ? limit : sp;
  }
  if (sp < floor)
    floor = sp;
  g_stats.floor = floor;
  void* r;
  const uintptr_t top = reinterpret_cast<uintptr_t>(__real__sbrk(0));
  const uintptr_t room = floor > top ? floor - top : 0;
  if (incr > 0 && (room < WIO_STACK_RESERVE ||
                   static_cast<uintptr_t>(incr) > room - WIO_STACK_RESERVE)) {
    ++g_stats.refusals;
    g_stats.last_incr = static_cast<uint32_t>(incr);
    g_stats.last_top = top;
    errno = ENOMEM;
    r = reinterpret_cast<void*>(-1);
  } else {
    r = __real__sbrk(incr);
  }
  __asm__ volatile("msr primask, %0" ::"r"(primask) : "memory");
  return r;
}

const WioSbrkStats* wio_sbrk_stats(void) {
  return &g_stats;
}

int wio_sbrk_describe(char* buf, size_t len) {
  if (!g_stats.refusals)
    return 0;
  return std::snprintf(
      buf, len,
      "[Wio] heap: %lu growths refused at the %u-byte stack reserve, the last "
      "of %lu bytes at top 0x%lx (stack floor 0x%lx)",
      static_cast<unsigned long>(g_stats.refusals),
      static_cast<unsigned>(WIO_STACK_RESERVE),
      static_cast<unsigned long>(g_stats.last_incr),
      static_cast<unsigned long>(g_stats.last_top),
      static_cast<unsigned long>(g_stats.floor));
}

}  // extern "C"
