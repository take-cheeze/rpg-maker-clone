// Renode-only Wio firmware that plays real game data: the same compiled engine
// as env:wio, with the game read from the microSD card's game folder when the
// card has one, else from the image game_rom.repl maps at game_rom_base()
// (wio_game_rom.cxx), and a heap census line per phase in the diagnostic log.
// scripts/wio/renode_game.bash builds the image, boots this and checks how far
// it got. The run's config below always comes from the image.
//
// The image's config (scripts/wio/game_rom.rb --config) sets the run:
//   frames=N        main_loop frames before stopping (default 600)
//   keys=F:KEY,...  RGSS::Input taps, pressed at frame F, released at F+1
//   new_game=0|1    auto-select New Game on the title (default 1)
//   preview_map=ID  start New Game on that map instead
//   battle_troop=ID, battle_play=0|1  the headless battle (see trace_host.cxx)
//   census=0|1      count live objects at each phase (a full GC each time)
//   every=N         also a census line every N frames (0: none)
//   eager_db=0|1    read RPG_RT.ldb whole (LCF_EAGER_DATABASE, LAZY_CHUNKS off)
//   eager_ce=0|1    common events as before LAZY_COMMON_EVENTS
//                   (RPG2K_EAGER_COMMON_EVENTS)
//   gc_step=N       mrb->gc.step_ratio (default WIO_GC_STEP_RATIO, as env:wio)
// The constants are the ones scripts/bc2cpp/trace_host.cxx sets, so a run
// here and a host run of the same config play the same frames.
//
// Each phase writes "P <phase> f=<frame> sbrk=<bytes> inuse=<bytes> ...":
// sbrk is the heap's extent (its high-water mark, newlib never trims below
// it), inuse the bytes malloc has handed out, sp_gap the room left between
// the heap top and the stack, stack_max the deepest the stack has been.
// With census=1, gc_inuse is inuse after the full GC the census runs.

#include <Arduino.h>
#include <lvgl.h>
#include <malloc.h>

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/error.h>
#include <mruby/gc.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

// The compiled entries catch C++ exceptions, which the wio build leaves out.
#define BC2CPP_ENTRY_BY_NAME
#include "bc2cpp_entry.hxx"
#include "rgss_rom_bitmaps.h"
#include "wio.hxx"
#include "wio_game_rom.h"
#include "wio_image_cache.h"
#include "wio_qspi_xip.h"
#include "wio_sd.h"

extern "C" void rpg_maker_init_shared_gems(mrb_state* mrb);
extern "C" void rpg_maker_init_rpg2k_gem(mrb_state* mrb);
extern "C" void rgss_set_display(mrb_state* M, lv_display_t* display);
extern "C" unsigned rgss_wio_mrb_state_size(void);
extern "C" char __end__;
extern "C" char __StackTop;
extern "C" void* _sbrk(ptrdiff_t);
// HEAPWALK (wio_heapwalk.cxx), linked by env:wio_renode_game_heapwalk only.
extern "C" void wio_heapwalk_begin(mrb_state*) __attribute__((weak));
extern "C" void wio_heapwalk_probe(const char*, long) __attribute__((weak));
extern "C" void wio_heapwalk_frame(long) __attribute__((weak));

namespace {

// Read by scripts/wio/renode_game.bash.
volatile uint32_t g_result = 0;
constexpr uint32_t kRunning = 0x6A6E0001;
constexpr uint32_t kDone = 0x6A6E00D0;
constexpr uint32_t kFailBoot = 0x6A6EBAD1;
constexpr uint32_t kFailNew = 0x6A6EBAD2;
constexpr uint32_t kFailFrame = 0x6A6EBAD3;
constexpr uint32_t kNoRom = 0x6A6EBAD4;

constexpr uint32_t kFailOom = 0x6A6EBAD5;

// Halts the core for good once the run is over, so the rest of Renode's time
// budget passes without emulating a spin.
[[noreturn]] void halt() {
  __disable_irq();
  SysTick->CTRL = 0;
  for (;;)
    __WFI();
}

// Live bytes of C++ allocations of kBigNew bytes or more: the bitmaps'
// pixel buffers (std::vector) are all of them.
constexpr size_t kBigNew = 4096;
size_t g_big_new = 0;
unsigned g_big_new_n = 0;

mrb_state* g_mrb = nullptr;
mrb_value g_game = mrb_nil_value();
long g_frame = 0;
long g_frames = 600;
long g_every = 0;
bool g_census = true;
char g_keys[512];
char g_scene[64];

long config_long(const char* key, long dflt) {
  char buf[32];
  return wio_game_rom_config(key, buf, sizeof(buf)) ? strtol(buf, nullptr, 10)
                                                    : dflt;
}

// LVGL's DMA flush never completes under Renode (no DMAC model), and nothing
// reads the panel here: hand every rendered area straight back.
void flush_cb(lv_display_t* disp, const lv_area_t*, uint8_t*) {
  lv_display_flush_ready(disp);
}

struct IvTbl {
  int size, alloc;
  mrb_value* ptr;
};
struct Census {
  uint32_t tt[MRB_TT_MAXDEFINE];
  uint32_t ivc, ivo, str_heap, ary_heap, mt_bytes;
};
int census_each(mrb_state*, RBasic* o, void* ud) {
  Census* c = static_cast<Census*>(ud);
  if (o->tt < MRB_TT_MAXDEFINE)
    c->tt[o->tt]++;
  const size_t ivslot = sizeof(mrb_value) + sizeof(mrb_sym);
  switch (o->tt) {
    case MRB_TT_CLASS:
    case MRB_TT_MODULE:
    case MRB_TT_SCLASS: {
      RClass* k = reinterpret_cast<RClass*>(o);
      for (mrb_mt_tbl* t = k->mt; t; t = t->next)
        if (!(t->alloc & MRB_MT_READONLY_BIT))
          c->mt_bytes +=
              (t->alloc & 0xffffff) * sizeof(mrb_mt_entry) + sizeof(mrb_mt_tbl);
      if (IvTbl* iv = reinterpret_cast<IvTbl*>(k->iv))
        c->ivc += iv->alloc * ivslot + sizeof(IvTbl);
      break;
    }
    case MRB_TT_OBJECT:
      if (IvTbl* iv =
              reinterpret_cast<IvTbl*>(reinterpret_cast<RObject*>(o)->iv))
        c->ivo += iv->alloc * ivslot + sizeof(IvTbl);
      break;
    case MRB_TT_STRING: {
      RString* s = reinterpret_cast<RString*>(o);
      if (!RSTR_EMBED_P(s) && !RSTR_SHARED_P(s) && !RSTR_FSHARED_P(s) &&
          !RSTR_NOFREE_P(s))
        c->str_heap += s->as.heap.aux.capa + 1;
      break;
    }
    case MRB_TT_ARRAY: {
      RArray* a = reinterpret_cast<RArray*>(o);
      if (!ARY_EMBED_P(a) && !ARY_SHARED_P(a))
        c->ary_heap += a->as.heap.aux.capa * sizeof(mrb_value);
      break;
    }
    default:
      break;
  }
  return MRB_EACH_OBJ_OK;
}

// The stack's low-water mark since the last probe: the gap between the heap
// top and the stack is painted, and the lowest overwritten word is the deepest
// the stack went (the heap only grows into it through _sbrk, which moves top).
constexpr uint32_t kPaint = 0xA5A5A5A5u;
uint32_t* g_painted_from = nullptr;
char* g_stack_low = nullptr;

void paint_gap(char* top, char* sp) {
  uint32_t* p =
      reinterpret_cast<uint32_t*>((reinterpret_cast<uintptr_t>(top) + 3) & ~3u);
  uint32_t* e = reinterpret_cast<uint32_t*>(sp - 64);
  g_painted_from = p;
  while (p < e)
    *p++ = kPaint;
}

char* stack_low(char* top, char* sp) {
  uint32_t* p = g_painted_from;
  if (!p)
    return sp;
  uint32_t* lo =
      reinterpret_cast<uint32_t*>((reinterpret_cast<uintptr_t>(top) + 3) & ~3u);
  if (p < lo)
    p = lo;
  while (reinterpret_cast<char*>(p) < sp && *p == kPaint)
    p++;
  return reinterpret_cast<char*>(p);
}

void probe(const char* phase) {
  struct mallinfo mi = mallinfo();
  char* sp;
  __asm__ volatile("mov %0, sp" : "=r"(sp));
  char* top = static_cast<char*>(_sbrk(0));
  char* low = stack_low(top, sp);
  if (!g_stack_low || low < g_stack_low)
    g_stack_low = low;
  wio_diag_printf(
      "P %s f=%ld sbrk=%u inuse=%u free=%u sp_gap=%u stack_max=%u "
      "big_new=%u/%u",
      phase, g_frame, static_cast<unsigned>(top - &__end__),
      static_cast<unsigned>(mi.uordblks), static_cast<unsigned>(mi.fordblks),
      static_cast<unsigned>(sp - top),
      static_cast<unsigned>(&__StackTop - g_stack_low),
      static_cast<unsigned>(g_big_new), g_big_new_n);
  if (g_mrb && g_census) {
    Census c{};
    mrb_objspace_each_objects(g_mrb, census_each, &c);
    mi = mallinfo();
    wio_diag_printf(" gc_inuse=%u ivc=%u ivo=%u str=%u ary=%u mt=%u tt",
                    static_cast<unsigned>(mi.uordblks), c.ivc, c.ivo,
                    c.str_heap, c.ary_heap, c.mt_bytes);
    for (int t = 0; t < MRB_TT_MAXDEFINE; ++t)
      if (c.tt[t])
        wio_diag_printf(" %d:%u", t, static_cast<unsigned>(c.tt[t]));
  }
  wio_diag_write("\n", 1);
  if (wio_heapwalk_probe)
    wio_heapwalk_probe(phase, g_frame);
  __asm__ volatile("mov %0, sp" : "=r"(sp));
  paint_gap(static_cast<char*>(_sbrk(0)), sp);
}

void report_exc(const char* where) {
  mrb_value exc = mrb_obj_value(g_mrb->exc);
  g_mrb->exc = nullptr;
  mrb_value s = mrb_inspect(g_mrb, exc);
  if (g_mrb->exc) {
    g_mrb->exc = nullptr;
    wio_diag_printf("EXC %s (uninspectable)\n", where);
    return;
  }
  wio_diag_printf("EXC %s %.*s\n", where, static_cast<int>(RSTRING_LEN(s)),
                  RSTRING_PTR(s));
}

void set_const(const char* name, mrb_value v) {
  mrb_const_set(g_mrb, mrb_obj_value(g_mrb->object_class),
                mrb_intern_cstr(g_mrb, name), v);
}

// The BC2CPP_HOST_KEYS taps of trace_host.cxx, from the config's keys=.
void tap_keys() {
  RClass* input =
      mrb_module_get_under(g_mrb, mrb_module_get(g_mrb, "RGSS"), "Input");
  for (const char* p = g_keys; *p;) {
    long f = strtol(p, const_cast<char**>(&p), 10);
    if (*p != ':')
      break;
    const char* k = ++p;
    while (*p && *p != ',')
      ++p;
    if (f == g_frame || f == g_frame - 1) {
      mrb_value key = mrb_const_get(g_mrb, mrb_obj_value(input),
                                    mrb_intern(g_mrb, k, p - k));
      mrb_funcall(g_mrb, mrb_obj_value(input),
                  f == g_frame ? "press" : "release", 1, key);
    }
    if (*p == ',')
      ++p;
  }
}

// A phase line whenever the scene changes.
void track_scene() {
  mrb_value name = bc2cpp_entry_RPG2k_current_scene_name(g_mrb, g_game);
  if (g_mrb->exc) {
    g_mrb->exc = nullptr;
    return;
  }
  name = mrb_obj_as_string(g_mrb, name);
  const char* s = RSTRING_PTR(name);
  const size_t n = RSTRING_LEN(name);
  if (n < sizeof(g_scene) &&
      (std::strlen(g_scene) != n || std::strncmp(g_scene, s, n) != 0)) {
    std::memcpy(g_scene, s, n);
    g_scene[n] = '\0';
    char phase[96];
    std::snprintf(phase, sizeof(phase), "scene:%s", g_scene);
    probe(phase);
  }
}

}  // namespace

// The core's operator new returns nullptr when malloc fails, and the caller
// (a bitmap's std::vector) then writes through it. Stop the run instead.
void* operator new(size_t n) {
  void* p = malloc(n);
  if (!p) {
    wio_diag_printf("OOM operator new %u bytes\n", static_cast<unsigned>(n));
    probe("oom");
    g_result = kFailOom;
    halt();
  }
  if (malloc_usable_size(p) >= kBigNew) {
    g_big_new += malloc_usable_size(p);
    ++g_big_new_n;
  }
  return p;
}
void* operator new[](size_t n) {
  return operator new(n);
}
void operator delete(void* p) noexcept {
  if (p && malloc_usable_size(p) >= kBigNew) {
    g_big_new -= malloc_usable_size(p);
    --g_big_new_n;
  }
  free(p);
}
void operator delete[](void* p) noexcept {
  operator delete(p);
}
void operator delete(void* p, size_t) noexcept {
  operator delete(p);
}
void operator delete[](void* p, size_t) noexcept {
  operator delete(p);
}

void setup(void) {
  wio_qspi_xip_require();
  g_result = kRunning;
  if (!wio_game_rom_config("frames", g_keys, sizeof(g_keys))) {
    g_result = kNoRom;
    return;
  }
  g_frames = config_long("frames", 600);
  g_every = config_long("every", 0);
  g_census = config_long("census", 1) != 0;
  if (!wio_game_rom_config("keys", g_keys, sizeof(g_keys)))
    g_keys[0] = '\0';
  probe("setup");
  wio_game_files_begin();
  const bool from_sd = wio_sd_state() == WIO_SD_GAME;
  probe("sd");

  lv_init();
  lv_display_t* disp = wio_display_create(320, 240);
  lv_display_set_flush_cb(disp, flush_cb);
  wio_input_init();

  if (rgss_wio_mrb_state_size() != sizeof(mrb_state)) {
    wio_diag_printf("[Wio] mrb_state is %u bytes in libmruby, %u here\n",
                    rgss_wio_mrb_state_size(),
                    static_cast<unsigned>(sizeof(mrb_state)));
    g_result = kFailBoot;
    return;
  }
  g_mrb = mrb_open_core();
  if (!g_mrb) {
    g_result = kFailBoot;
    return;
  }
  // GC_STEP_RATIO: as env:wio sets it (wio_rgss_boot_main.cxx).
  g_mrb->gc.step_ratio =
      static_cast<int>(config_long("gc_step", WIO_GC_STEP_RATIO));
  if (wio_heapwalk_begin)
    wio_heapwalk_begin(g_mrb);
  rpg_maker_init_shared_gems(g_mrb);
  if (!g_mrb->exc)
    rpg_maker_init_rpg2k_gem(g_mrb);
  if (g_mrb->exc) {
    report_exc("init");
    probe("failed");
    g_result = kFailBoot;
    return;
  }
  mrb_full_gc(g_mrb);
  probe("init");

  rgss_set_display(g_mrb, disp);
  // What the boot leaves in the GC arena is kept by a constant or by the game,
  // registered below; the arena entries would hold the rest forever.
  const int boot_ai = mrb_gc_arena_save(g_mrb);
  // scripts/wio/game_rom.rb's decoded images, read in place (ROM_BITMAP).
  // They are the image's game's; a card game's come from its pack, through
  // the QSPI cache (IMAGE_CACHE).
  size_t bitmaps_len = 0;
  const void* bitmaps =
      from_sd ? nullptr : wio_game_rom_file("/rgss/bitmaps", &bitmaps_len);
  if (bitmaps)
    rgss_set_rom_bitmaps(bitmaps, bitmaps_len, WIO_GAME_ROOT);
  else if (from_sd)
    wio_image_cache_begin(WIO_GAME_ROOT);
  set_const("GAME_DIR", mrb_str_new_cstr(g_mrb, WIO_GAME_ROOT));
  set_const("RTP_DIR", mrb_str_new_cstr(g_mrb, ""));
  set_const("TEST_PLAY", mrb_false_value());
  set_const("NO_RENDER_WAIT", mrb_true_value());
  set_const("RPG2K_NEW_GAME", mrb_bool_value(config_long("new_game", 1) != 0));
  set_const("RPG2K_CONTINUE", mrb_false_value());
  set_const("RPG2K_PREVIEW_MAP",
            mrb_fixnum_value(config_long("preview_map", 0)));
  set_const("RPG2K_BATTLE_TROOP",
            mrb_fixnum_value(config_long("battle_troop", 0)));
  set_const("RPG2K_BATTLE_PLAY",
            mrb_bool_value(config_long("battle_play", 0) != 0));
  if (config_long("eager_db", 0) != 0)
    set_const("LCF_EAGER_DATABASE", mrb_true_value());
  if (config_long("eager_ce", 0) != 0)
    set_const("RPG2K_EAGER_COMMON_EVENTS", mrb_true_value());

  mrb_value args = mrb_ary_new(g_mrb);
  g_game = bc2cpp_entry_RPG2k_new(g_mrb, 1, &args);
  if (g_mrb->exc) {
    report_exc("RPG2k.new");
    probe("failed");
    g_result = kFailNew;
    return;
  }
  mrb_gc_register(g_mrb, g_game);
  mrb_gc_arena_restore(g_mrb, boot_ai);
#ifdef MRB_CLASS_SHRINK
  // The boot and RPG2k.new have set the classes' constants: their tables give
  // their doubling's spare room back.
  mrb_class_shrink(g_mrb);
#endif
  probe("new");
}

void loop(void) {
  if (g_result != kRunning)
    halt();
  if (g_frame >= g_frames) {
    probe("end");
    mrb_full_gc(g_mrb);
    probe("end_gc");
    wio_image_cache_report();
    wio_diag_printf("DONE frames=%ld\n", g_frame);
    g_result = kDone;
    return;
  }
  // Every call below leaves its result in the GC arena (mrb_funcall's
  // contract); without the restore it grows by a slot per frame.
  const int ai = mrb_gc_arena_save(g_mrb);
  if (wio_heapwalk_frame)
    wio_heapwalk_frame(g_frame);
  track_scene();
  tap_keys();
  if (!g_mrb->exc)
    bc2cpp_entry_RPG2k_main_loop(g_mrb, g_game);
  mrb_gc_arena_restore(g_mrb, ai);
  if (g_mrb->exc) {
    const bool clean = MRB_EXC_EXIT_P(g_mrb->exc);
    if (!clean)
      report_exc("main_loop");
    probe("stop");
    wio_diag_printf("STOP frame=%ld reason=%s\n", g_frame,
                    clean ? "exit" : "error");
    g_result = clean ? kDone : kFailFrame;
    return;
  }
  ++g_frame;
  if (g_every > 0 && g_frame % g_every == 0) {
    char phase[32];
    std::snprintf(phase, sizeof(phase), "frame%ld", g_frame);
    probe(phase);
  }
}
