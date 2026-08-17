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
// word boxing needs on 32-bit). The size should be validated against a real
// game on-device -- the BRINGUP heartbeat below already reports free RAM --
// but 8 MB is generous: the rpg2k+lcf+rgss mrblib costs ~1.4 MB of class
// definitions on a 64-bit host (roughly half on the PSP's 32-bit MIPS), and a
// real LCF database (Nepheshel's 1.3 MB .ldb) plus the maps and scene objects
// fit well inside, while still leaving most of the ~24 MB for the LVGL pool,
// the draw buffers and the decoded-bitmap heap.
constexpr size_t kMrbArenaSize = 8u * 1024u * 1024u;
alignas(16) uint8_t g_mrb_arena[kMrbArenaSize];

constexpr size_t kMrbAlign = 16;
struct MrbBlock {
  size_t size;     // payload bytes, a multiple of kMrbAlign
  MrbBlock* next;  // next free block in ascending address order (free blocks)
};
static_assert(sizeof(MrbBlock) <= kMrbAlign,
              "block header must fit one alignment unit");

MrbBlock* g_mrb_free = nullptr;

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
    "Up", "Down", "Left", "Right", "A", "B", "C"};

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
  std::snprintf(buf, sizeof(buf), "%s/%s", dir, rel);
  return file_exists(buf);
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
void show_keys(uint32_t mask) {
  static uint32_t last = 0xffffffffu;
  if (mask == last)
    return;
  last = mask;

  char buf[64];
  int n = 0;
  n += snprintf(buf + n, sizeof(buf) - n, "Keys:");
  bool any = false;
  for (int k = 0; k < PSP_INPUT_KEY_COUNT && n < static_cast<int>(sizeof(buf));
       ++k) {
    if (mask & (1u << k)) {
      n += snprintf(buf + n, sizeof(buf) - n, " %s", kKeyNames[k]);
      any = true;
    }
  }
  if (!any)
    snprintf(buf + n, sizeof(buf) - n, " (none)");
  lv_label_set_text(g_status_label, buf);
}

}  // namespace

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
  psp_display_create(game_info ? game_info->width : PSP_SCR_WIDTH,
                     game_info ? game_info->height : PSP_SCR_HEIGHT);
  psp_input_init();
  build_ui();

  // Open the interpreter and report whether it succeeded. `M` is kept alive
  // (never mrb_close()d) for the rest of the process, the same as every other
  // target's entry point.
  mrb_state* const M = mrb_open();
  {
    char buf[48];
    const int n = std::snprintf(buf, sizeof(buf), "RPG2K_PSP_MRUBY_OPEN %s\n",
                                M ? "ok" : "FAILED");
    if (n > 0)
      psp_write(buf, n);
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
    mrb_const_set(M, mrb_obj_value(M->object_class),
                  mrb_intern_lit(M, "GAME_DIR"), mrb_str_new_cstr(M, kGameDir));
    mrb_const_set(M, mrb_obj_value(M->object_class),
                  mrb_intern_lit(M, "RTP_DIR"), mrb_str_new_cstr(M, ""));

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
    const int n = std::snprintf(
        buf, sizeof(buf), "RPG2K_PSP_GAME_START %s %s\n",
        game_info ? game_info->class_name : "none", game_start_result);
    if (n > 0)
      psp_write(buf, n);
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
        const int n =
            std::snprintf(buf, sizeof(buf), "RPG2K_PSP_GAME_STOP %s\n",
                          clean_exit ? "exit" : "error");
        if (n > 0)
          psp_write(buf, n);
      }
    } else {
      show_keys(psp_input_scan());
      lv_timer_handler();
    }
    if (frame % 200 == 0) {
      lv_mem_monitor_t mon;
      lv_mem_monitor(&mon);
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
      char buf[192];
      const int n = std::snprintf(
          buf, sizeof(buf),
          "RPG2K_PSP_BRINGUP frame=%u free=%u maxfree=%u lvgl_used=%u "
          "lvgl_max=%u stack_free=%d stack_used_max=%u\n",
          frame, static_cast<unsigned>(sceKernelTotalFreeMemSize()),
          static_cast<unsigned>(sceKernelMaxFreeMemSize()),
          static_cast<unsigned>(mon.total_size - mon.free_size),
          static_cast<unsigned>(mon.max_used), stack_free, stack_used_max);
      if (n > 0)
        psp_write(buf, n);
    }
    sceKernelDelayThread(5000);  // ~5 ms, matching the Wio loop's delay(5)
  }

  sceKernelExitGame();
  return 0;
}
