// ROM_GRAPH_PROBE (scripts/wio/rom_graph.bash probe): the wio libmruby.a, booted as wio_renode_game_main.cxx boots it
// (mrb_open_core, the shared gems, the rpg2k gem, a full GC), linked into a Linux program that qemu-arm runs. The
// boot is the firmware's own object code, so the class graph it dumps to stdout is the one a Renode run dumps.
#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <sys/stat.h>

#include <mruby.h>
#include <mruby/rom_graph.h>

#include "rom_graph_ram_classes.h"

// Linux EABI system calls (svc #0, the number in r7); newlib's own are bare-metal stubs.
static long sys3(long nr, long a, long b, long c) {
  register long r0 __asm__("r0") = a;
  register long r1 __asm__("r1") = b;
  register long r2 __asm__("r2") = c;
  register long r7 __asm__("r7") = nr;
  __asm__ volatile("svc #0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r7) : "memory");
  return r0;
}
enum { SYS_WRITE = 4, SYS_EXIT_GROUP = 248 };

static void put(int fd, const char *s, size_t n) {
  while (n) {
    long w = sys3(SYS_WRITE, fd, (long)s, (long)n);
    if (w <= 0) break;
    s += w;
    n -= (size_t)w;
  }
}
static void puts2(const char *s) { put(2, s, strlen(s)); }

__attribute__((noreturn)) void _exit(int code) {
  for (;;) sys3(SYS_EXIT_GROUP, code, 0, 0);
}
int _write(int fd, const char *s, int n) {
  put(fd, s, (size_t)n);
  return n;
}
int _read(int fd, char *s, int n) { (void)fd; (void)s; (void)n; return 0; }
int _close(int fd) { (void)fd; return -1; }
int _fstat(int fd, struct stat *st) { (void)fd; st->st_mode = S_IFCHR; return 0; }
int _isatty(int fd) { (void)fd; return 1; }
int _lseek(int fd, int o, int w) { (void)fd; (void)o; (void)w; return 0; }
int _kill(int p, int s) { (void)p; (void)s; return -1; }
int _getpid(void) { return 1; }

static char heap[64 << 20];
static size_t heap_used;
void *_sbrk(ptrdiff_t n) {
  if (heap_used + (size_t)n > sizeof(heap)) {
    errno = ENOMEM;
    return (void *)-1;
  }
  void *p = heap + heap_used;
  heap_used += (size_t)n;
  return p;
}

void *__dso_handle = 0;
void _init(void) {}
void _fini(void) {}

// What the firmware links beside libmruby.a (the Arduino core, LVGL, TFT_eSPI) is stubs.rb's functions, which land
// here. A clock is allowed: the boot stores one only in RGSS, a RAM class whose immediates the graph leaves out. Any
// other call during the boot fails the probe, since its real result could shape the graph.
static const char *const clocks[] = {"lv_tick_get", "millis", "micros", NULL};
static int stub_calls;
int probe_stub_hit(const char *name) {
  int clock = 0;
  for (const char *const *c = clocks; *c; c++) clock |= strcmp(*c, name) == 0;
  if (!clock) stub_calls++;
  puts2("probe: stub ");
  puts2(name);
  puts2("\n");
  return 0;
}

static void line(void *ud, const char *s) {
  (void)ud;
  put(1, s, strlen(s));
  put(1, "\n", 1);
}

void rpg_maker_init_shared_gems(mrb_state *mrb);
void rpg_maker_init_rpg2k_gem(mrb_state *mrb);

int main(void) {
  // Static constructors (a TFT_eSPI object) ran before main; only the boot's own calls count.
  const int before = stub_calls;
  mrb_state *mrb = mrb_open_core();
  if (!mrb) {
    puts2("probe: mrb_open_core failed\n");
    return 2;
  }
  rpg_maker_init_shared_gems(mrb);
  if (!mrb->exc) rpg_maker_init_rpg2k_gem(mrb);
  if (mrb->exc) {
    puts2("probe: gem init raised\n");
    mrb_print_error(mrb);
    return 3;
  }
  mrb_full_gc(mrb);
  if (stub_calls != before) {
    puts2("probe: the boot called a stub\n");
    return 4;
  }
  static const char *const ram_classes[] = {ROM_GRAPH_RAM_CLASSES, NULL};
  mrb_rom_graph_dump(mrb, line, NULL, ram_classes);
  puts2(mrb_rom_graph_active(mrb) ? "probe: on the graph\n" : "probe: heap classes\n");
  return 0;
}

__attribute__((naked, noreturn)) void _start(void) {
  __asm__ volatile("bl __libc_init_array\n bl main\n bl _exit\n");
}
