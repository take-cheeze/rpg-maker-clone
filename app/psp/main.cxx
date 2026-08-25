// PlayStation Portable EBOOT entry point -- HAL bring-up plus the real
// RPG2k/XP/VX/VX Ace scene tree.
//
// This slice proves the HAL compiles and runs on the PSP and that libmruby.a
// (built for the psp target by build_config.rb, linked in via
// app/psp/CMakeLists.txt) actually links and boots on real MIPS/pspdev: it
// stands up the LVGL display (psp_display_create), scans the pad
// (psp_input_scan), draws a small status screen that echoes the pressed keys,
// opens an mruby interpreter (mrb_open), and -- if a project is present at
// kGameDir -- constructs the detected maker's game class (RPG2k/RPGXP/RPGVX)
// and drives its per-frame #main_loop the same way the Emscripten build
// drives it from rpg_start_game's callback (mruby's gems are already
// registered the moment mrb_open() returns; nothing extra wires RGSS in,
// since libmruby.a's gem_init runs every bundled gem -- see
// build_config.rb's rpg_maker_gems). main() owns the loop and pumps LVGL
// once per iteration when no game is running, and through the game's own
// Graphics.update (which flushes LVGL and polls the pad via rgss_psp_poll,
// mruby-rgss/src/psp_input_bridge.cxx) once one is -- the same "host owns
// the loop" shape the Emscripten and Wio builds use. Its per-second
// heartbeat also reports real free-memory and LVGL-pool numbers (see the
// RPG2K_PSP_BRINGUP marker below), which is ADR 0047's P1: measuring the
// HAL's own footprint on real hardware/an emulator, now against a real
// game's usage once one is present at kGameDir instead of just the idle HAL.
//
// The display is created at each maker's *native* logical resolution
// (RPG2k 320x240, RPGXP 640x480, RPGVX/VX Ace 544x416 -- matching
// RPGXP_WIDTH/RPGVX_WIDTH in src/main.cxx), not the PSP panel's fixed
// 480x272: RGSS::Graphics.width/height and everything the game draws derive
// directly from the LVGL display's own resolution
// (lv_display_get_horizontal_resolution in mruby-rgss/src/lib.cxx), so
// creating it at the panel's resolution instead would silently distort
// every game's own coordinate math. mruby-rgss/src/psp.cxx centers that
// logical canvas on the panel and clips whatever falls outside it -- for
// RPG2k, comfortably smaller than the panel in both dimensions, that is
// just letterboxing; for RPGXP/RPGVX, both larger than the panel in both
// dimensions (they were designed for a desktop window), that means only a
// same-scale, centered *window* onto the game's own screen is ever visible
// -- a real, known limitation (not full-canvas scaling, which this bring-up
// does not attempt), not a correctness or memory-safety one.
//
// mrb_open() here uses mruby's own default allocator (plain malloc) rather
// than routing through lv_malloc the way the desktop build does -- ADR 0047's
// P2 (share LVGL's pool vs. a separate arena) is now decided for this target
// (see below): the interpreter's whole live heap is routed through a
// fixed-size arena of its own (mrb_basic_alloc_func) instead of LVGL's pool
// -- which only aligns to 4 bytes on a 32-bit build, too weak for mruby's word
// boxing, the same reason the wasm build opts out -- and instead of the
// unbounded default malloc. When the arena is exhausted the allocator returns
// NULL and mruby raises a catchable NoMemoryError rather than the interpreter
// growing until it collides with the decoded-bitmap heap.

#include <cstddef>
#include <cstdio>
#include <cstring>

#include <lvgl.h>
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/error.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <pspiofilemgr.h>
#include <pspkernel.h>
#include <pspsysmem.h>
#include <pspthreadman.h>

#include "psp.hxx"

// Standard pspsdk module metadata for a user-mode EBOOT. THREAD_ATTR_VFPU keeps
// the VFPU state saved across the main thread's context switches.
PSP_MODULE_INFO("rpg2k", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(THREAD_ATTR_USER | THREAD_ATTR_VFPU);

// ADR 0047's P5: the main-thread stack is an explicit, *verified* size rather
// than pspsdk's implicit default (which is what this EBOOT relied on while it
// was an LVGL-only bring-up, before the interpreter and the real scene tree
// were linked in). 256 KB is the size that already runs the real RPG2k scene
// tree here; what makes it verified rather than guessed is the heartbeat
// below, which reports how deep the interpreter has actually recursed into it
// (stack_free / stack_used_max), so a deeper-recursing title shows up in the
// numbers instead of as a crash. ADR 0007 flagged mruby's init-time recursion
// as a stack risk on constrained targets; this is the measurement that closes
// it for the PSP.
//
// The macro expands to a plain `unsigned int sce_newlib_stack_kb_size` that
// pspsdk's crt0 reads when it creates the main thread, so it has to sit at
// file scope with a literal-ish initialiser -- hence the separate KB constant
// used to derive the byte figure the heartbeat subtracts from.
#define RPG2K_PSP_MAIN_STACK_KB 256
PSP_MAIN_THREAD_STACK_SIZE_KB(RPG2K_PSP_MAIN_STACK_KB);

namespace {

constexpr unsigned kMainStackBytes = RPG2K_PSP_MAIN_STACK_KB * 1024u;

// A tiny libc-free string builder, used for every marker/status string this
// file writes instead of std::snprintf. Not a style preference: confirmed
// directly (gdb on a resulting core dump, reproduced twice) that pspsdk's
// sysclib_snprintf, which PPSSPP-headless implements only partially, leaves
// emulator state corrupted enough that the *host* process later segfaults
// inside PPSSPP's own sceKernelCreateLwMutex -- the very first snprintf call
// this file made (path_exists' "%s/%s" join, before any interpreter or
// display code even runs) was enough to trigger it a few syscalls later.
// Nothing here needs a format string: every call site is either joining two
// known strings or rendering a handful of small integers, both of which
// StrBuf does with no libc call beyond memcpy (a compiler intrinsic, never
// routed through sysclib_). Whether real hardware shares PPSSPP's bug is
// unknown and beside the point -- there is no reason to depend on a
// partially-implemented libc path for something this simple either way.
class StrBuf {
 public:
  StrBuf(char* buf, size_t cap) : buf_(buf), cap_(cap) {}

  void str(const char* s) {
    while (*s && len_ + 1 < cap_)
      buf_[len_++] = *s++;
  }

  // Length-bounded variant for bytes that aren't a NUL-terminated C string --
  // an mruby String's RSTRING_PTR/RSTRING_LEN, which mruby happens to
  // NUL-terminate internally but which this call does not rely on.
  void str(const char* s, size_t n) {
    for (size_t i = 0; i < n && len_ + 1 < cap_; ++i)
      buf_[len_++] = s[i];
  }

  void uint(unsigned v) {
    char digits[10];  // enough for any 32-bit unsigned value
    int n = 0;
    do {
      digits[n++] = static_cast<char>('0' + v % 10);
      v /= 10;
    } while (v);
    while (n > 0 && len_ + 1 < cap_)
      buf_[len_++] = digits[--n];
  }

  void sint(int v) {
    if (v < 0) {
      str("-");
      // Widen to long before negating so INT_MIN doesn't overflow -v.
      uint(static_cast<unsigned>(-static_cast<long>(v)));
    } else {
      uint(static_cast<unsigned>(v));
    }
  }

  // NUL-terminates (for LVGL's lv_label_set_text) and returns the buffer.
  const char* c_str() {
    buf_[len_ < cap_ ? len_ : cap_ - 1] = '\0';
    return buf_;
  }

  int length() const { return static_cast<int>(len_); }

 private:
  char* buf_;
  size_t cap_;
  size_t len_ = 0;
};

lv_obj_t* g_status_label = nullptr;

// ADR 0047's P2 (the mruby/LVGL allocator split), decided for this target:
// mruby gets its own bounded arena instead of sharing LVGL's pool or running
// unbounded on plain malloc. Sharing LVGL's pool is not an option here the way
// it is on desktop -- LVGL's builtin TLSF pool only aligns to 4 bytes on a
// 32-bit build (lv_mem_core_builtin.c's ALIGN_MASK), which breaks mruby's word
// boxing, the same reason the wasm build opts out -- and an unbounded malloc
// lets the interpreter eat the whole ~24 MB until it collides with the
// decoded-bitmap heap. A fixed arena bounds it: when the pool is exhausted
// mrb_basic_alloc_func returns NULL and mruby raises a catchable NoMemoryError
// (mrb_realloc -> mrb_raise_nomemory) instead of corrupting RAM.
//
// This is a first-fit free-list allocator with splitting and coalescing; every
// block is 16-byte aligned (enough for the 8-byte RVALUE alignment mruby's
// word boxing needs on 32-bit). The size is validated against a real game
// (Nepheshel, New Game) under PPSSPP-headless: at 8 MB the arena fills to its
// last byte during the first map load and the failed-allocation recovery paths
// (mrb_realloc_simple's full-GC-and-retry, then a NoMemoryError raise that
// itself has to unwind through cipop's env-unshare allocation) corrupt the VM
// callinfo chain -- frames pointing into freed memory and even onto the native
// C stack -- which aborts inside catch_handler_find on the very next raise.
// At 12 MB the same scenario runs millions of frames with steady-state usage
// pinned at ~12.0 MB (mruby grows to fill capacity and GCs under pressure;
// one transient exhaustion per 3 minutes, recovered cleanly by the GC retry),
// while 16 MB starves the newlib/sbrk heap that decoded bitmaps and the C++
// exception machinery share (std::bad_alloc during map play). So 12 MB was
// the measured working size on this ~24 MB target -- with a known sharp edge
// left open on purpose, this same comment already warned: "a game that
// genuinely exhausts 12 MB will hit the same corrupting-unwind cliff until
// the failure paths are hardened." The heartbeat below reports the arena's
// own occupancy (arena_used) alongside the system figures precisely to catch
// that day arriving.
//
// It arrived under CI: `psp-smoke-game`'s `.psp_ci_new_game` marker
// (docs/adr/0047-psp-memory-budget.md's P1c) drives Nepheshel through a real
// New Game into map 371, and `ppsspp-headless` segfaults deterministically
// (byte-identical across three separate runs) once arena_used climbs to
// 11,887,824 B -- 94.5% of the 12 MB ceiling. Tried spending 512 KiB of the
// ~764 KiB of untouched OS-level headroom every heartbeat's `free=782336`
// figure showed (12.5 MB, see PR #1357) to see whether the ceiling was the
// real problem: it was not. The same run reached one heartbeat further
// (arena_used 12,976,496 B at frame=400, 99.0% of the *new* 12.5 MB
// ceiling) and then crashed the same way -- the cliff tracks whatever
// ceiling is in force almost exactly (94.5% then 99.0%, both right before
// the crash, on two different sizes), which is about as clean a
// confirmation as one experiment can give that this is genuine capacity
// exhaustion hitting the corrupting-unwind cliff above, not an unrelated
// PPSSPP HLE gap. Reverted to 12 MB: 12.5 MB bought nothing (a bigger map,
// a real XP/VX project, or just more play time would hit the same wall
// further out regardless of size) while permanently spending headroom the
// newlib/sbrk heap may need. The actual fix is hardening the unwind path
// itself, not raising this number -- out of scope for a PSP-port change;
// see the ADR's P1c for the full trail.
constexpr size_t kMrbArenaSize = 12u * 1024u * 1024u;
alignas(16) uint8_t g_mrb_arena[kMrbArenaSize];

// P1c mitigation: mruby's own GC threshold (mrb_obj_alloc's `gc->threshold <
// gc->live` in 3rd/mruby/src/gc.c) is sized off object-count growth ratios --
// it has no idea this arena has a hard 12 MB ceiling at all, so it can let
// reclaimable garbage pile up for a while between automatic collections. That
// widens exactly the window this file's own comment above already flags as
// dangerous: the closer a real allocation gets to running out of room, the
// more likely it is to need mrb_realloc_simple's full-GC-and-retry recovery,
// and the failure paths on the far side of *that* retry failing are the
// unhardened corrupting-unwind cliff. Forcing an extra mrb_full_gc() here,
// well before the arena is actually full, buys back headroom from garbage
// mruby's own heuristic hasn't gotten around to reclaiming yet, so real
// allocations are less likely to ever reach that retry path in the first
// place. It cannot help with genuine live-data growth (a full GC cannot
// reclaim reachable objects) or with fragmentation (this arena never
// compacts), only with deferred-but-reclaimable garbage -- a real, if
// partial, mitigation, not a fix for the underlying unwind-path gap.
constexpr size_t kMrbArenaGcHighWater = kMrbArenaSize * 85 / 100;
constexpr uint32_t kMrbArenaGcCheckFrames = 30;

constexpr size_t kMrbAlign = 16;
struct MrbBlock {
  size_t size;     // payload bytes, a multiple of kMrbAlign
  MrbBlock* next;  // next free block in ascending address order (free blocks)
};
static_assert(sizeof(MrbBlock) <= kMrbAlign,
              "block header must fit one alignment unit");

MrbBlock* g_mrb_free = nullptr;

void mrb_arena_init();

// Live bytes (payload + headers) currently handed out, for the heartbeat.
size_t mrb_arena_used() {
  mrb_arena_init();
  size_t free_bytes = 0;
  for (MrbBlock* b = g_mrb_free; b; b = b->next)
    free_bytes += kMrbAlign + b->size;
  return kMrbArenaSize - free_bytes;
}

size_t mrb_align_up(size_t n) {
  return (n + kMrbAlign - 1) & ~(kMrbAlign - 1);
}

// The arena starts as one free block spanning everything after its own header.
void mrb_arena_init() {
  if (g_mrb_free)
    return;
  MrbBlock* first = reinterpret_cast<MrbBlock*>(g_mrb_arena);
  first->size = kMrbArenaSize - kMrbAlign;
  first->next = nullptr;
  g_mrb_free = first;
}

void* mrb_arena_alloc(size_t n) {
  mrb_arena_init();
  const size_t need = mrb_align_up(n);
  MrbBlock* prev = nullptr;
  for (MrbBlock* b = g_mrb_free; b; prev = b, b = b->next) {
    if (b->size < need)
      continue;
    // Split when the leftover can hold another block (header + 16 B payload).
    if (b->size - need >= 2 * kMrbAlign) {
      MrbBlock* rest = reinterpret_cast<MrbBlock*>(
          reinterpret_cast<uint8_t*>(b) + kMrbAlign + need);
      rest->size = b->size - need - kMrbAlign;
      rest->next = b->next;
      b->size = need;
      if (prev)
        prev->next = rest;
      else
        g_mrb_free = rest;
    } else {
      if (prev)
        prev->next = b->next;
      else
        g_mrb_free = b->next;
    }
    return reinterpret_cast<uint8_t*>(b) + kMrbAlign;
  }
  return nullptr;  // arena exhausted -> mruby raises NoMemoryError
}

void mrb_arena_free(void* p) {
  if (!p)
    return;
  mrb_arena_init();
  MrbBlock* b =
      reinterpret_cast<MrbBlock*>(reinterpret_cast<uint8_t*>(p) - kMrbAlign);
  // Insert back into the address-ordered free list.
  MrbBlock* prev = nullptr;
  MrbBlock* cur = g_mrb_free;
  while (cur && cur < b) {
    prev = cur;
    cur = cur->next;
  }
  b->next = cur;
  if (prev)
    prev->next = b;
  else
    g_mrb_free = b;
  // Coalesce with the physically-next block when it is free and adjacent.
  if (cur && reinterpret_cast<uint8_t*>(b) + kMrbAlign + b->size ==
                 reinterpret_cast<uint8_t*>(cur)) {
    b->size += kMrbAlign + cur->size;
    b->next = cur->next;
  }
  // Coalesce with the physically-previous block when it is free and adjacent.
  if (prev && reinterpret_cast<uint8_t*>(prev) + kMrbAlign + prev->size ==
                  reinterpret_cast<uint8_t*>(b)) {
    prev->size += kMrbAlign + b->size;
    prev->next = b->next;
  }
}

void* mrb_arena_realloc(void* p, size_t n) {
  if (n == 0) {
    mrb_arena_free(p);
    return nullptr;
  }
  if (!p)
    return mrb_arena_alloc(n);
  MrbBlock* b =
      reinterpret_cast<MrbBlock*>(reinterpret_cast<uint8_t*>(p) - kMrbAlign);
  const size_t need = mrb_align_up(n);
  if (b->size >= need)
    return p;  // already fits; no move
  void* nbuf = mrb_arena_alloc(need);
  if (!nbuf)
    return nullptr;
  std::memcpy(nbuf, p, b->size < n ? b->size : n);
  mrb_arena_free(p);
  return nbuf;
}

// Names for the RGSS key ids, indexed by PspKey, for the on-screen echo.
const char* const kKeyNames[PSP_INPUT_KEY_COUNT] = {
    "Up", "Down", "Left", "Right", "A",  "B",  "C",  "",  "",  "",   "",   "",
    "",   "",     "",     "",      "",   "",   "",   "",  "",  "N0", "N1", "N2",
    "N3", "N4",   "N5",   "N6",    "N7", "N8", "N9", "+", "-", "*",  "/",  "."};

// The Memory Stick install location this build looks for a project at --
// matching app/psp/README.md's own install instructions (copy EBOOT.PBP to
// this same PSP/GAME/rpg2k directory). One EBOOT, one game, no in-app project
// picker: unlike the desktop build (--game_dir) or the browser build (the
// page's own loader unzips a project at runtime), there is no way for this
// build to be told a different location at launch.
const char kGameDir[] = "ms0:/PSP/GAME/rpg2k";

bool file_exists(const char* path) {
  FILE* const f = std::fopen(path, "rb");
  if (!f)
    return false;
  std::fclose(f);
  return true;
}

bool path_exists(const char* dir, const char* rel) {
  char buf[96];
  StrBuf sb(buf, sizeof(buf));
  sb.str(dir);
  sb.str("/");
  sb.str(rel);
  return file_exists(sb.c_str());
}

// An RPG Maker VX / VX Ace project: mirrors is_rpgvx_game in src/main.cxx.
// Checked before the XP predicate below, which only looks for Game.ini -- a
// VX project has one too.
bool is_rpgvx_game(const char* gd) {
  return path_exists(gd, "Data/System.rvdata2") ||
         path_exists(gd, "Data/System.rvdata") ||
         path_exists(gd, "Game.rgss3a") || path_exists(gd, "Game.rgss2a");
}

// An RPG Maker XP project: mirrors is_xp_game in src/main.cxx.
bool is_xp_game(const char* gd) {
  if (is_rpgvx_game(gd))
    return false;
  const bool xp_data =
      path_exists(gd, "Data/System.rxdata") || path_exists(gd, "Game.rgssad");
  return path_exists(gd, "Game.ini") && xp_data;
}

// The mruby class to construct and the LVGL display resolution to create for
// it -- see the file-level comment on why this has to be each maker's own
// native resolution, not the panel's.
struct GameInfo {
  const char* class_name;
  int32_t width;
  int32_t height;
};

// RPG Maker 2000/2003's native screen size, matching src/main.cxx's --width/
// --height defaults. RPGXP_WIDTH/HEIGHT and RPGVX_WIDTH/HEIGHT there are the
// other two.
constexpr int32_t kRpg2kWidth = 320;
constexpr int32_t kRpg2kHeight = 240;
constexpr int32_t kXpWidth = 640;
constexpr int32_t kXpHeight = 480;
constexpr int32_t kVxWidth = 544;
constexpr int32_t kVxHeight = 416;

// Which maker's project (if any) is present at kGameDir, mirroring
// src/main.cxx's dispatch order: RPG2k (RPG_RT.ldb) first, then VX / VX Ace
// (whose own archives/data files the XP predicate would otherwise also
// match), then XP. Returns nullptr if none matched -- the idle HAL bring-up.
const GameInfo* detect_game(void) {
  static const GameInfo kRpg2k{"RPG2k", kRpg2kWidth, kRpg2kHeight};
  static const GameInfo kXp{"RPGXP", kXpWidth, kXpHeight};
  static const GameInfo kVx{"RPGVX", kVxWidth, kVxHeight};
  if (path_exists(kGameDir, "RPG_RT.ldb"))
    return &kRpg2k;
  if (is_rpgvx_game(kGameDir))
    return &kVx;
  if (is_xp_game(kGameDir))
    return &kXp;
  return nullptr;
}

// Write a buffer to the PSP stdout (fd 1) and stderr (fd 2). Under an emulator
// the host captures these; on real hardware they go nowhere. The length is
// passed explicitly rather than derived with strlen: under PPSSPP pspsdk's libc
// string helpers resolve to firmware stubs (sysclib_strlen) that the emulator
// only partially implements, so a strlen-derived length can come back 0 and the
// write emits nothing. Both fds are written so whichever PPSSPP surfaces to its
// log is captured.
void psp_write(const char* s, int len) {
  sceIoWrite(1, s, len);
  sceIoWrite(2, s, len);
}

// The HOME-button exit callback, so the EBOOT quits cleanly back to the XMB.
int exit_callback(int /*arg1*/, int /*arg2*/, void* /*common*/) {
  sceKernelExitGame();
  return 0;
}

int callback_thread(SceSize /*args*/, void* /*argp*/) {
  const int cbid =
      sceKernelCreateCallback("Exit Callback", exit_callback, nullptr);
  sceKernelRegisterExitCallback(cbid);
  sceKernelSleepThreadCB();
  return 0;
}

void setup_callbacks(void) {
  const int thid = sceKernelCreateThread("update_thread", callback_thread, 0x11,
                                         0xFA0, 0, nullptr);
  if (thid >= 0)
    sceKernelStartThread(thid, 0, nullptr);
}

void build_ui(void) {
  lv_obj_t* scr = lv_screen_active();
  lv_obj_set_style_bg_color(scr, lv_color_black(), 0);

  lv_obj_t* title = lv_label_create(scr);
  lv_label_set_text(title, "rpg2k on PSP\nHAL bring-up");
  lv_obj_set_style_text_color(title, lv_color_white(), 0);
  lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 10);

  g_status_label = lv_label_create(scr);
  lv_label_set_text(g_status_label, "Keys: (none)");
  lv_obj_set_style_text_color(g_status_label, lv_palette_main(LV_PALETTE_AMBER),
                              0);
  lv_obj_align(g_status_label, LV_ALIGN_CENTER, 0, 20);
}

// Rebuild the "Keys:" line from the current pad bitmask.
void show_keys(uint64_t mask) {
  static uint64_t last = 0xffffffffffffffffull;
  if (mask == last)
    return;
  last = mask;

  char buf[64];
  StrBuf sb(buf, sizeof(buf));
  sb.str("Keys:");
  bool any = false;
  for (int k = 0; k < PSP_INPUT_KEY_COUNT; ++k) {
    if (mask & (1ull << k)) {
      if (kKeyNames[k][0] == '\0')
        continue;
      sb.str(" ");
      sb.str(kKeyNames[k]);
      any = true;
    }
  }
  if (!any)
    sb.str(" (none)");
  lv_label_set_text(g_status_label, sb.c_str());
}

// Appends " t_us=N free=N maxfree=N lvgl_used=N lvgl_max=N stack_free=N
// stack_used_max=N arena_used=N" -- the figure tail every RPG2K_PSP_*
// diagnostic marker in this file carries (see the BRINGUP heartbeat below for
// what each field means; ADR 0047 is the budget these exist to measure
// against). t_us is sceKernelGetSystemTimeLow() -- microseconds on the
// console's own free-running clock (the same source mruby-rgss/src/psp.cxx's
// LVGL tick callback uses), not wall-clock time or time-since-process-start:
// subtract one marker's t_us from a later one's to get an elapsed duration
// between them (mrb_open cost, load-to-title-screen cost, ...) without this
// file needing to know or care what "now" means beyond that. stack_used_max
// is a parameter rather than recomputed here because only the periodic
// heartbeat tracks a running maximum across many samples -- a one-shot
// marker's own high-water mark is just its single sample (see
// append_mem_snapshot below, which fills that in for one-shot callers).
void append_mem_fields(StrBuf& sb, int stack_free, unsigned stack_used_max) {
  lv_mem_monitor_t mon;
  lv_mem_monitor(&mon);
  sb.str(" t_us=");
  sb.uint(static_cast<unsigned>(sceKernelGetSystemTimeLow()));
  sb.str(" free=");
  sb.uint(static_cast<unsigned>(sceKernelTotalFreeMemSize()));
  sb.str(" maxfree=");
  sb.uint(static_cast<unsigned>(sceKernelMaxFreeMemSize()));
  sb.str(" lvgl_used=");
  sb.uint(static_cast<unsigned>(mon.total_size - mon.free_size));
  sb.str(" lvgl_max=");
  sb.uint(static_cast<unsigned>(mon.max_used));
  sb.str(" stack_free=");
  sb.sint(stack_free);
  sb.str(" stack_used_max=");
  sb.uint(stack_used_max);
  sb.str(" arena_used=");
  sb.uint(static_cast<unsigned>(mrb_arena_used()));
}

// Convenience for a one-shot marker (as opposed to the periodic BRINGUP
// heartbeat, which tracks stack_used_max across many samples itself): samples
// the main thread's stack once and reports that single sample as its own
// high-water mark, since there is no earlier history to compare it against.
void append_mem_snapshot(StrBuf& sb) {
  const int stack_free = sceKernelGetThreadStackFreeSize(0);
  const unsigned stack_used =
      (stack_free >= 0 && static_cast<unsigned>(stack_free) <= kMainStackBytes)
          ? kMainStackBytes - static_cast<unsigned>(stack_free)
          : 0;
  append_mem_fields(sb, stack_free, stack_used);
}

// Appends the active scene's class name ("RPG2k::Scene::Title",
// "RPG2k::Scene::Map", ... for RPG2k; a project's own bundled script classes
// for XP/VX, whatever they happen to be named) via each maker's
// RPG2k#current_scene_name/RPGXP#current_scene_name/
// RPGVX#current_scene_name (mruby-rpg2k, mruby-rpgxp, mruby-rpgvx mrblib) --
// added alongside this file's own scene-agnostic markers so the BRINGUP
// heartbeat can attribute its memory numbers to what the player was actually
// looking at, not just a frame count. Appends "none" for no game running or
// (defensively) the call itself raising -- a diagnostic marker must never be
// the thing that aborts the frame loop. RSTRING_PTR/RSTRING_LEN are read and
// copied out here, synchronously, rather than a raw pointer being handed back
// to the caller -- mruby's GC gives no lifetime guarantee once the string
// value itself is no longer reachable from this scope.
void append_scene_name(StrBuf& sb, mrb_state* M, mrb_value game_obj) {
  const mrb_value name = mrb_funcall(M, game_obj, "current_scene_name", 0);
  if (M->exc) {
    M->exc = nullptr;
    sb.str("none");
    return;
  }
  if (!mrb_string_p(name)) {
    sb.str("none");
    return;
  }
  sb.str(RSTRING_PTR(name), static_cast<size_t>(RSTRING_LEN(name)));
}

}  // namespace

// Wires RGSS::_display (mruby-rgss/src/lib.cxx's get_display) to the LVGL
// display psp_display_create stood up below -- every other target's entry
// point calls this right after mrb_open() (src/main.cxx), but the PSP one
// never did, leaving RGSS::_display nil. get_display()'s mrb_assert on it
// compiles to a real assert() under -DMRB_DEBUG (this build's flags), so the
// first RGSS call that touches the display (e.g. Sprite.new, via LVGL's
// canvas creation) aborted the process; the abort path's own cleanup code
// then calls strlen() on a boxed mruby value, which is the
// sysclib_strlen(0x11e) crash ADR 0047's bug 10 was tracking.
extern "C" void rgss_set_display(mrb_state* M, lv_display_t* d);

// mruby 4.0 has no per-state allocator hook; a program overrides the global
// mrb_basic_alloc_func to supply its own allocator. Defining it here means the
// linker never pulls mruby's default (plain realloc) from libmruby.a -- the
// same pattern src/main.cxx uses to route mruby through LVGL's pool on
// desktop. On the PSP every mruby allocation (the whole live object graph,
// strings, the parsed LCF database) comes out of the fixed arena above, so the
// interpreter's footprint is bounded regardless of what a game does.
extern "C" void* mrb_basic_alloc_func(void* p, size_t size) {
  if (size == 0) {
    mrb_arena_free(p);
    return nullptr;
  }
  return mrb_arena_realloc(p, size);
}

int main(void) {
  // Emitted before any LVGL/display init so the CI smoke test can tell "the
  // EBOOT booted and its stdout is captured" apart from "it crashed during
  // init". A string literal with a compile-time length keeps this marker free
  // of any libc call, so it survives PPSSPP's partial libc HLE.
  static const char kBootMarker[] = "RPG2K_PSP_BOOT\n";
  psp_write(kBootMarker, static_cast<int>(sizeof(kBootMarker) - 1));

  setup_callbacks();

  // Detected before the display exists: which maker's project (if any) is
  // present decides the display's own logical resolution (see the
  // file-level comment), so this has to run first. It is a handful of plain
  // fopen probes, nothing mruby-related, so it does not need the
  // interpreter open yet either.
  const GameInfo* const game_info = detect_game();

  lv_init();
  lv_display_t* const display =
      psp_display_create(game_info ? game_info->width : PSP_SCR_WIDTH,
                         game_info ? game_info->height : PSP_SCR_HEIGHT);
  psp_input_init();
  build_ui();

  // Baseline for "how much did mrb_open() itself cost": everything up to
  // here (the HAL, LVGL, the display and its widgets) is already live, but no
  // mruby allocation -- core VM state, the symbol table, or any gem's classes
  // -- has happened yet, so arena_used is always 0 at this marker. Subtract
  // this from RPG2K_PSP_MRUBY_OPEN's own free= (or add up arena_used, which
  // is the more direct number: mrb_open() links every gem's mrblib in, the
  // same "full gembox, no game loaded yet" state ADR 0047's Finding 1
  // host-proxy measurement estimated at ~1.2-1.4 MB before a device number
  // existed for it) to get mrb_open()'s real device cost.
  {
    char buf[256];
    StrBuf sb(buf, sizeof(buf));
    sb.str("RPG2K_PSP_PRE_MRUBY_OPEN");
    append_mem_snapshot(sb);
    sb.str("\n");
    psp_write(buf, sb.length());
  }

  // Open the interpreter and report whether it succeeded. `M` is kept alive
  // (never mrb_close()d) for the rest of the process, the same as every other
  // target's entry point.
  mrb_state* const M = mrb_open();
  {
    char buf[256];
    StrBuf sb(buf, sizeof(buf));
    sb.str("RPG2K_PSP_MRUBY_OPEN ");
    sb.str(M ? "ok" : "FAILED");
    append_mem_snapshot(sb);
    sb.str("\n");
    psp_write(buf, sb.length());
  }

  // GAME_DIR/RTP_DIR are load-bearing mruby constants: mruby-rpg2k/mruby-rpgxp/
  // mruby-rpgvx/mruby-rgss's own mrblib read them directly (RPG_RT.ldb/.lmt
  // paths, Game.ini, asset/audio search paths, ...), the same as every other
  // target's entry point sets them (src/main.cxx). RTP_DIR is empty -- this
  // build is a single self-contained project per EBOOT, no shared RTP
  // install to point at.
  mrb_value game_obj = mrb_nil_value();
  bool have_game = false;
  if (M) {
    rgss_set_display(M, display);

    mrb_const_set(M, mrb_obj_value(M->object_class),
                  mrb_intern_lit(M, "GAME_DIR"), mrb_str_new_cstr(M, kGameDir));
    mrb_const_set(M, mrb_obj_value(M->object_class),
                  mrb_intern_lit(M, "RTP_DIR"), mrb_str_new_cstr(M, ""));
    // RPG2k#initialize's native_test_play? (mruby-rpg2k/mrblib/main.rb)
    // references this constant directly (rescuing NameError if it's
    // missing) -- every other target's entry point defines it
    // (src/main.cxx), this build has no command line to carry a real
    // Test Play flag on, so it is always false.
    mrb_const_set(M, mrb_obj_value(M->object_class),
                  mrb_intern_lit(M, "TEST_PLAY"), mrb_false_value());
    // RPG2K_NEW_GAME/RPG2K_CONTINUE/RPG2K_PREVIEW_MAP/RPG2K_BATTLE_TROOP:
    // Scene::Title (mruby-rpg2k/mrblib/scene/title.rb) and RPG2k#headless_
    // battle_troop/#preview_map_id (mruby-rpg2k/mrblib/main.rb) reference
    // these directly, each wrapped in its own `rescue StandardError` since
    // src/main.cxx (the only other target that defines them, from its own
    // CLI flags) is the one place they normally come from -- this build has
    // no command line, so they are always "unset", the same defaults
    // src/main.cxx's own flags fall back to. Defining them (rather than
    // relying on the rescue to catch their absence, the same as every other
    // undefined-optional-constant site in this file) sidesteps a separate,
    // deeper issue: raising the first real exception of the process's life
    // here doesn't reliably unwind on this target -- see ADR 0047's bug-10
    // follow-up finding -- so leaving these undefined crashes instead of
    // being caught.
    //
    // RPG2K_NEW_GAME is the one exception: it is driven by whether a
    // `.psp_ci_new_game` marker file sits next to the project's own data at
    // kGameDir, not always false like the other three. Scene::Title's
    // auto_select? (mruby-rpg2k/mrblib/scene/title.rb) reads it to
    // auto-pick "New Game" with no input needed, the same mechanism
    // src/main.cxx's own --rpg2k_new_game already drives on desktop for
    // scripts/compare-nepheshel-wine.bash -- this just gives the PSP target
    // a way to opt in without a command line. A real release's own game
    // folder never carries this file (nothing in the editor or this
    // codebase's own packaging ever writes it), so every real player still
    // lands on an ordinary title screen; only CI's psp-smoke-game job
    // creates it, to reach Scene::Map for ADR 0047's per-scene memory
    // numbers instead of measuring the idle title screen forever.
    const bool ci_new_game = path_exists(kGameDir, ".psp_ci_new_game");
    mrb_const_set(M, mrb_obj_value(M->object_class),
                  mrb_intern_lit(M, "RPG2K_NEW_GAME"),
                  mrb_bool_value(ci_new_game));
    mrb_const_set(M, mrb_obj_value(M->object_class),
                  mrb_intern_lit(M, "RPG2K_CONTINUE"), mrb_false_value());
    mrb_const_set(M, mrb_obj_value(M->object_class),
                  mrb_intern_lit(M, "RPG2K_PREVIEW_MAP"), mrb_fixnum_value(0));
    mrb_const_set(M, mrb_obj_value(M->object_class),
                  mrb_intern_lit(M, "RPG2K_BATTLE_TROOP"), mrb_fixnum_value(0));

    const char* game_start_result;
    if (game_info) {
      // No TestPlay/HideTitle words -- this build has no command line to
      // carry them on.
      const mrb_value args = mrb_ary_new(M);
      game_obj =
          mrb_obj_new(M, mrb_class_get(M, game_info->class_name), 1, &args);
      if (M->exc) {
        // Leaves no game running; falls through to the idle HAL loop below,
        // same as "not_found". The display stays sized for the maker whose
        // construction failed rather than reverting to the panel's own
        // resolution -- a rare path (the project's own files exist but its
        // database failed to parse), not worth the extra bookkeeping to fix
        // up for what the idle status screen looks like.
        M->exc = nullptr;
        game_start_result = "FAILED";
      } else {
        // Keeps `game_obj` reachable from the GC across the frame loop below
        // -- mruby's GC only sees the VM's own stack/registers and explicit
        // roots, not arbitrary C++ locals, the same reason src/main.cxx
        // registers its own game_obj (Emscripten's rpg_start_game).
        mrb_gc_register(M, game_obj);
        have_game = true;
        game_start_result = "ok";
      }
    } else {
      game_start_result = "not_found";
    }
    char buf[64];
    StrBuf sb(buf, sizeof(buf));
    sb.str("RPG2K_PSP_GAME_START ");
    sb.str(game_info ? game_info->class_name : "none");
    sb.str(" ");
    sb.str(game_start_result);
    sb.str("\n");
    psp_write(buf, sb.length());

    // One-shot snapshot, only on a successful construction: the game object
    // (database, map tree, and -- for RPG2k -- Scene::Title) is fully built,
    // but the frame loop below has not run even once, so nothing has been
    // drawn or updated yet. This is "memory right before the title screen"
    // (docs/adr/0047-psp-memory-budget.md): everything the load itself cost,
    // with none of the per-frame steady-state drift the BRINGUP heartbeat
    // measures afterward.
    if (have_game) {
      char rbuf[256];
      StrBuf rb(rbuf, sizeof(rbuf));
      rb.str("RPG2K_PSP_GAME_READY ");
      rb.str(game_info->class_name);
      append_mem_snapshot(rb);
      rb.str("\n");
      psp_write(rbuf, rb.length());
    }
  }

  // The loop runs ~200 iterations/second (5 ms delay); emit a heartbeat line
  // roughly once a second. The CI smoke test asserts this marker appears,
  // proving the EBOOT not only boots but keeps pumping frames (see the
  // psp-smoke job in .github/workflows/build.yml). It also carries real
  // memory numbers -- ADR 0047's P1 -- so the memory-budget estimates there
  // get replaced with device measurements instead of staying host-proxy
  // guesses: sceKernelTotalFreeMemSize/sceKernelMaxFreeMemSize (pspsysmem.h)
  // for the PSP's ~24 MB user partition, and lv_mem_monitor for LVGL's own
  // pool (app/psp/lv_conf.h's 4 MB LV_MEM_SIZE) -- currently used and the
  // max_used high-water mark, which is the number that actually matters for
  // sizing that pool once the interpreter is linked. stack_free/stack_used_max
  // are ADR 0047's P5, the same idea for the main-thread stack the module
  // metadata above now sizes explicitly.
  for (uint32_t frame = 0;; ++frame) {
    if (have_game) {
      // RPG2k#main_loop (mruby-rpg2k/mrblib/main.rb) is the single-frame step
      // #start loops forever on desktop; driving it once per C++ frame here
      // instead keeps this loop, not mruby, in charge of the process, the
      // same shape src/main.cxx's rpg_start_game gives the browser. It calls
      // Graphics.update itself, which flushes LVGL (mruby-rgss/src/lib.cxx's
      // gfx_update) and polls the pad (rgss_psp_poll) -- so neither
      // lv_timer_handler() nor show_keys()/psp_input_scan() below are needed
      // while a game is driving its own frame.
      mrb_funcall(M, game_obj, "main_loop", 0);
      if (M->exc) {
        // MRB_EXC_EXIT_P distinguishes a clean Kernel#exit (RPG_RT's own
        // "Shutdown" title command, via mruby-exit) from an actual crash --
        // read before clearing, since clearing drops the flag with the
        // exception object.
        const bool clean_exit = MRB_EXC_EXIT_P(M->exc);
        M->exc = nullptr;
        have_game = false;
        char buf[48];
        StrBuf sb(buf, sizeof(buf));
        sb.str("RPG2K_PSP_GAME_STOP ");
        sb.str(clean_exit ? "exit" : "error");
        sb.str("\n");
        psp_write(buf, sb.length());
      }
    } else {
      show_keys(psp_input_scan());
      lv_timer_handler();
    }
    if (have_game && frame % kMrbArenaGcCheckFrames == 0 &&
        mrb_arena_used() >= kMrbArenaGcHighWater) {
      mrb_full_gc(M);
    }
    if (frame % 200 == 0) {
      // ADR 0047's P5. sceKernelGetThreadStackFreeSize scans the low (deep)
      // end of the thread's stack for the 0xFF fill pspsdk leaves there at
      // creation and reports how much of it is still untouched. Because a
      // down-growing stack never restores those bytes to 0xFF once a frame has
      // written over them, *any* single sample is already the high-water mark
      // of how deep this thread has ever recursed -- not an instantaneous
      // depth. stack_used_max still takes the running maximum so a sample that
      // comes back negative (an error return) or from a differently-sized
      // stack cannot walk the reported figure backwards.
      static unsigned stack_used_max = 0;
      const int stack_free = sceKernelGetThreadStackFreeSize(0);
      if (stack_free >= 0 &&
          static_cast<unsigned>(stack_free) <= kMainStackBytes) {
        const unsigned used =
            kMainStackBytes - static_cast<unsigned>(stack_free);
        if (used > stack_used_max)
          stack_used_max = used;
      }
      char buf[256];
      StrBuf sb(buf, sizeof(buf));
      sb.str("RPG2K_PSP_BRINGUP frame=");
      sb.uint(frame);
      sb.str(" scene=");
      if (have_game)
        append_scene_name(sb, M, game_obj);
      else
        sb.str("none");
      append_mem_fields(sb, stack_free, stack_used_max);
      sb.str("\n");
      psp_write(buf, sb.length());
    }
    sceKernelDelayThread(5000);  // ~5 ms, matching the Wio loop's delay(5)
  }

  sceKernelExitGame();
  return 0;
}
