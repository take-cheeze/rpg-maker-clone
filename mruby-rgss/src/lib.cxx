#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/data.h>
// debug.h/irep.h/proc.h: the log bridge reads the script location of the frame
// that logged out of the running proc's irep debug info (see
// script_location below).
#include <mruby/debug.h>
#include <mruby/hash.h>
#include <mruby/irep.h>
#include <mruby/proc.h>
#include <mruby/string.h>
#include <mruby/value.h>
#include <mruby/variable.h>

#include <uni_algo/norm.h>
#include <uni_algo/ranges.h>
#include <uni_algo/ranges_conv.h>

#include "default_font.hxx"
#include "gfx.hxx"
#include "mrb_array_access.hxx"
#include "profiler.hxx"
#include "rgss_construct.hxx"
#include "rgss_number.hxx"
#include "rgss_rom_bitmaps.h"
#include "shinonome.hxx"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

// The Wio Terminal's bare arm-none-eabi newlib -- and the Maix Amigo's bare
// riscv64-unknown-elf newlib just the same (a hard #error in <dirent.h> on
// both, unlike PSP's own pspsdk newlib) -- has no dirent implementation at
// all -- find_font_path below (its only caller here) degrades to "no custom
// Fonts/ folder on this board" rather than a build that cannot compile at
// all; a bundled default font (default_font.cxx, gated the same way) still
// resolves through its own fixed-path fallback.
#if defined(WIO_TERMINAL) || defined(MAIX_BUILD)
typedef void DIR;
static inline DIR* opendir(const char*) {
  return nullptr;
}
static inline void closedir(DIR*) {}
struct dirent {
  char d_name[1];
};
static inline dirent* readdir(DIR*) {
  return nullptr;
}
#else
#include <dirent.h>
#endif

#include <iostream>

namespace gfx = rgss::gfx;
using rgss::kPixelARGB8888;
using rgss::kPixelI8;
using rgss::kPixelRGB888;
using rgss::pixel_size;
using rgss::PixelFormat;

// The asset search this engine actually performs only ever tries .png,
// .jpg/.jpeg, .bmp (via stb, all three formats an RPG Maker XP/VX RTP mixes)
// and .xyz (the custom decoder below, not stb's). None of stb's other format
// decoders — GIF, PSD, TGA, HDR, PIC, PNM — are reachable from any loader in
// this codebase (confirmed by grep: no stbi__gif/psd/tga/hdr/pic/pnm-specific
// symbol is referenced anywhere). Compiling them in cost real bytes for
// nothing: on the PSP every PT_LOAD segment of the EBOOT is mapped into RAM at
// launch (same reasoning as the uni-algo trim), so this is live RAM there, not
// just file/flash size, and it shrinks the desktop/wasm/wio/android binaries
// for free the same way that trim did.
#define STBI_NO_GIF
#define STBI_NO_PSD
#define STBI_NO_TGA
#define STBI_NO_HDR
#define STBI_NO_PIC
#define STBI_NO_PNM

// JPEG is real, reachable code on every *other* target: RGSS::Bitmap::
// EXTENSIONS (this gem's own mrblib/lib.rb) tries :jpg/:jpeg because the RPG
// Maker XP RTP genuinely ships .jpg title screens (see the comment on that
// constant). wio, though, is a single_format_only build (build_config.rb) --
// it compiles mruby-rpg2k alone, never mruby-rpgxp/mruby-rpgvx/mruby-wolf, so
// no Ruby path on this target can ever select the XP/VX maker that .jpg
// candidate exists for. RPG2k::Game#initialize (mruby-rpg2k/mrblib/main.rb)
// installs RGSS::Bitmap::RPG2K_EXTENSIONS instead -- `[:bmp, :png, :xyz]`,
// measured directly against a real RPG_RT.exe under wine to have "no
// `.jpg`/`.jpeg` candidate ... at all" -- before any asset load this engine's
// own boot sequence performs. So on wio specifically, every stbi__jpeg_*
// function stb_image.h compiles in is dead weight the same way GIF/PSD/TGA/
// HDR/PIC/PNM already are above: linked and flashed, never reachable at
// runtime. Scoped to WIO_TERMINAL only (not a blanket single_format_only
// check) so desktop/wasm/android/psp, none of which this measurement
// touched, keep their current behaviour unchanged.
#ifdef WIO_TERMINAL
#define STBI_NO_JPEG
#endif

#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

// This is the single translation unit that compiles the stb_truetype
// implementation for the whole build. mruby-mvjs depends on this gem and only
// includes the header, so its glyph rasteriser (mvcanvas.cxx) resolves against
// the symbols emitted here — keep exactly one STB_TRUETYPE_IMPLEMENTATION.
// Not on wio: nothing there can load a TrueType face.
#if !defined(WIO_TERMINAL)
#define STB_TRUETYPE_IMPLEMENTATION
#include <stb_truetype.h>
#endif

// Defined in terminal.cxx (same gem).  A no-op unless the game was started with
// a terminal backend (--sixel / --iterm); forwards terminal keyboard input to
// RGSS::Input.
extern "C" void rgss_terminal_poll(mrb_state* M);

// Defined in input_bridge.cxx (same gem).  A no-op unless the SDL window
// backend is active and has captured key events; drains them into RGSS::Input.
extern "C" void rgss_sdl_poll(mrb_state* M);

// Defined in input_bridge.cxx (same gem).  Buffers one already-translated key
// transition, the way the executable's SDL event watch does; exposed to Ruby as
// RGSS::Input._push so a headless test can drive an input frame.
extern "C" void rgss_sdl_input_push(int key, bool press);

// Defined in input_bridge.cxx (same gem).  The latest pointer state captured by
// the SDL backend (0 / not-pressed under the other backends); exposed to Ruby
// as RGSS.mouse_x / mouse_y / mouse_pressed? so MV's TouchInput bridge can read
// it.
extern "C" int rgss_mouse_x(void);
extern "C" int rgss_mouse_y(void);
extern "C" int rgss_mouse_pressed(void);

// Defined in audio.cxx (same gem).  Registers the native RGSS::Audio methods
// and drives the audio backend's per-frame work (a no-op when no backend is
// installed).
void rgss_audio_define(mrb_state* M, RClass* rgss);
extern "C" void rgss_audio_frame(void);

// Defined in tts.cxx (same gem). Registers the native RGSS::Tts methods (a
// no-op backend when --zundamon_tts was not passed).
void rgss_tts_define(mrb_state* M, RClass* rgss);

// Defined in log_bridge.cxx (same gem). Forwards one already-buffered
// $stderr line to the executable's ng-log hook (a no-op on mrbtest, PSP and
// Wio Terminal, which never install one -- see include/terminal.hxx's
// "Stderr log bridge" section).
void log_bridge_write(const char* msg,
                      size_t len,
                      const char* file = nullptr,
                      int line = 0);
// Also defined in log_bridge.cxx: writes to the real stderr (unconditionally)
// and forwards through log_bridge_write. Used by the native (non-Ruby)
// diagnostics below that used to be a bare fprintf(stderr, ...).
void log_bridge_write_stderr(const char* msg);

// Defined in window_title.cxx (same gem). Hands the running game's own title
// to the executable's hook -- the SDL window's caption, or the browser tab
// under Emscripten -- and remembers it. Beyond that record it is a no-op where
// no hook is installed (the terminal backends, mrbtest, PSP, Wio Terminal);
// see include/terminal.hxx's "Window title bridge" section.
void window_title_set(const char* title);
const std::string& window_title_get();

#if defined(WIO_TERMINAL)
// Defined in wio_input_bridge.cxx; scans the board's buttons/5-way switch and
// forwards press/release edges to RGSS::Input.  Guarded so the desktop/wasm
// builds, which do not compile the Wio backend, need no such symbol.
extern "C" void rgss_wio_poll(mrb_state* M);
#endif

#if defined(PSP_BUILD)
// Defined in psp_input_bridge.cxx; scans the PSP pad and forwards press/release
// edges to RGSS::Input.  Guarded so the desktop/wasm builds, which do not
// compile the PSP backend, need no such symbol.
extern "C" void rgss_psp_poll(mrb_state* M);
#endif

#if defined(MAIX_BUILD)
// Defined platform-side (app/wio/src/maix_input.cxx); scans the Amigo touch
// panel and forwards press/release edges to RGSS::Input. Guarded so the
// desktop/wasm builds, which do not compile the Maix backend, need no such
// symbol. Unlike the Wio bridge above, this lives outside libmruby.a
// entirely (nothing Arduino-touching is compiled at rake time), so there is
// no mruby-side counterpart file -- just this declaration.
extern "C" void rgss_maix_poll(mrb_state* M);
#endif

namespace {
// RGSS.default_font_path -> the bundled default UI font, or nil when none is
// installed (it is downloaded, not committed -- see assets/fonts/README.md).
// The makers whose text expects a TrueType face point RGSS::Font.default_path
// at this on boot; see font_default_path below for why that is opt-in.
mrb_value default_font_path_m(mrb_state* M, mrb_value self) {
  const std::string& path = rgss::default_font_path();
  return path.empty() ? mrb_nil_value()
                      : mrb_str_new(M, path.data(), path.size());
}

mrb_value to_nfd(mrb_state* M, mrb_value self) {
  const char* ptr;
  mrb_int len;
  mrb_get_args(M, "s", &ptr, &len);
#ifdef WIO_TERMINAL
  // uni-algo's NFD decomposition/combining-class tables are ~94 KB on their
  // own -- a meaningful slice of this
  // board's 496 KB flash budget for a feature that exists to paper over a
  // real but narrow bug class (a macOS-authored zip/archive storing
  // filenames in NFD while the game data references them in NFC, or vice
  // versa). mrblib/lib.rb's exist_with_ext calls this as a *second-chance*
  // fallback only when the exact filename already failed to resolve, so
  // returning the input unchanged here just means that second chance never
  // fires on this target -- an asset whose filename's normalization form
  // already matches (by far the common case: this project's own export
  // pipeline writes one consistent form) still loads exactly as before.
  return mrb_str_new(M, ptr, len);
#else
  std::string nfd = una::norm::to_nfd_utf8(std::string_view(ptr, len));
  return mrb_str_new(M, nfd.data(), nfd.size());
#endif
}

// Inflate a zlib stream and return the decompressed bytes as a String. RGSS
// stores each Data/Scripts.rxdata section (and .xyz graphics) as a standard
// zlib stream (header byte 0x78); the RGSS script host (mruby-rpgxp) needs to
// decompress those sections before it can eval them. Reuses stb_image's zlib
// decoder -- already linked for PNG/XYZ loading -- so no extra dependency is
// pulled in. Falls back to a raw (headerless) DEFLATE decode the way load_xyz
// does, and raises RGSS::RGSSError when the stream cannot be inflated.
#if !defined(WIO_TERMINAL)  // dead weight on wio: no Ruby path reaches it
mrb_value zlib_inflate_native_body(mrb_state* M,
                                   mrb_value self,
                                   const char* ptr,
                                   mrb_int len) {
  int outlen = 0;
  char* raw = stbi_zlib_decode_malloc(ptr, (int)len, &outlen);
  if (!raw)
    raw = stbi_zlib_decode_noheader_malloc(ptr, (int)len, &outlen);
  if (!raw)
    mrb_raisef(M,
               mrb_class_get_under_id(M, mrb_module_get_id(M, MRB_SYM(RGSS)),
                                      MRB_SYM(RGSSError)),
               "zlib inflate failed: %s", stbi_failure_reason());
  mrb_value out = mrb_str_new(M, raw, outlen < 0 ? 0 : outlen);
  stbi_image_free(raw);
  return out;
}

mrb_value zlib_inflate(mrb_state* M, mrb_value self) {
  const char* ptr;
  mrb_int len;
  mrb_get_args(M, "s", &ptr, &len);
  return zlib_inflate_native_body(M, self, ptr, len);
}
#endif  // !defined(WIO_TERMINAL)

using V = ::mrb_value;

double clamp255(double v) {
  return v < 0 ? 0 : (v > 255 ? 255 : v);
}

double clamp_signed255(double v) {
  return v < -255 ? -255 : (v > 255 ? 255 : v);
}

struct Rect {
  // DataType<T>::data_type's own struct_name: a plain,
  // manually-supplied label instead of typeid(T).name(), so this file
  // doesn't need RTTI just to name its own mrb_data_type entries.
  static constexpr const char* kTypeName = "Rect";
  mrb_int x{0}, y{0}, width{0}, height{0};
};

// RGSS Color: floating point RGBA components in the range 0..255.
struct Color {
  static constexpr const char* kTypeName = "Color";
  double red{0}, green{0}, blue{0}, alpha{255};
};

// RGSS Tone: red/green/blue in -255..255 and gray in 0..255.
struct Tone {
  static constexpr const char* kTypeName = "Tone";
  double red{0}, green{0}, blue{0}, gray{0};
};

// RGSS Table: 1..3 dimensional array of 16bit integers used for map data.
struct Table {
  static constexpr const char* kTypeName = "Table";
  int32_t dim{1};
  int32_t xsize{0}, ysize{1}, zsize{1};
  std::vector<int16_t> data;
};

// Live decoded-Bitmap-buffer byte totals, split by how the buffer's contents
// came to be, since the two have very different growth shapes: `decoded` is
// real asset pixels (CharSet/Picture/Chipset/... -- what
// mruby-rpg2k/mrblib/scene/map.rb's LRUBitmapCache now bounds, and what
// the PSP memory budget calls "the third pool"),
// while `blank` is everything that never touched a decoder: render targets,
// snapshots, canvases (`Bitmap.new(w, h)`), and a `Bitmap#clone`'s own copy
// (RPG::Cache's hue-variant pattern -- copies an existing buffer, decodes
// nothing itself, so it is not double-counted against `decoded` even though
// the bitmap it was cloned from was). Exposed to app/psp/main.cxx's own
// heartbeat via rgss_bitmap_bytes_decoded/_blank below, the same
// extern-"C"-without-a-shared-header pattern rgss_set_display already uses
// across this boundary.
static size_t g_bitmap_bytes_decoded = 0;
static size_t g_bitmap_bytes_blank = 0;

// PIXEL_GC: pixels are plain heap blocks, invisible to a GC that counts
// objects, so dropped bitmaps hold theirs until enough other objects pile up.
// pixel_alloc runs a full GC first once the live pixel bytes have grown past
// what survived the last one by that much again (kPixelGcGrowth at least),
// and once more when malloc cannot give it the bytes; failing again, it raises
// NoMemoryError. malloc is asked first because the Wio core's operator new
// answers nullptr instead of throwing. Never while LVGL draws (PixelGcHold):
// collecting a sprite deletes its LVGL object.
static mrb_state* g_pixel_mrb = nullptr;
static int g_pixel_gc_hold = 0;
static size_t g_pixel_gc_base = 0;
constexpr size_t kPixelGcGrowth = 256 * 1024;

struct PixelGcHold {
  PixelGcHold() { ++g_pixel_gc_hold; }
  ~PixelGcHold() { --g_pixel_gc_hold; }
  PixelGcHold(const PixelGcHold&) = delete;
};

static size_t pixel_bytes_live() {
  return g_bitmap_bytes_decoded + g_bitmap_bytes_blank;
}

static void pixel_gc(mrb_state* M) {
  mrb_full_gc(M);
  g_pixel_gc_base = pixel_bytes_live();
}

static bool pixel_fits(size_t n) {
  // volatile: a compiler may otherwise fold an unused malloc to success.
  void* volatile p = std::malloc(n);
  std::free(p);
  return p != nullptr;
}

// Runs `alloc`, which allocates `n` bytes of pixels (see PIXEL_GC).
// A sprite's rows are expanded at most this many bytes at a time (at least one
// row). A deferred bitmap's draw holds two such buffers, the rows and their
// composition; on the Wio they are what is left of the heap at the title.
#if defined(WIO_TERMINAL)
constexpr uint32_t kSpriteViewChunkBytes = 1024;
#else
constexpr uint32_t kSpriteViewChunkBytes = 4096;
#endif

// DRAW_HEADROOM: the frame's draw runs under PixelGcHold and takes its row
// buffers from operator new, which collects nothing, while the GC paces itself
// by objects: a dropped Rect holds about 64 bytes of malloc, so the title's
// garbage filled the 192 KB Wio's heap long before a GC was due. Before the
// draw, a full GC makes the room when it is not there, unless no object was
// allocated since the last one (it would free nothing).
constexpr size_t kDrawHeadroom = 4 * kSpriteViewChunkBytes;
static size_t g_headroom_gc_live = 0;

static void draw_headroom(mrb_state* M) {
  if (g_pixel_gc_hold || M->gc.live == g_headroom_gc_live ||
      pixel_fits(kDrawHeadroom))
    return;
  pixel_gc(M);
  g_headroom_gc_live = M->gc.live;
}

template <class F>
void pixel_alloc(size_t n, F&& alloc) {
  mrb_state* const M = g_pixel_gc_hold ? nullptr : g_pixel_mrb;
  if (M && n > 0) {
    const size_t live = pixel_bytes_live();
    // Something freed pixels since: what is left is the new base.
    if (live < g_pixel_gc_base)
      g_pixel_gc_base = live;
    if (live + n > g_pixel_gc_base + std::max(kPixelGcGrowth, g_pixel_gc_base))
      pixel_gc(M);
    if (!pixel_fits(n)) {
      pixel_gc(M);
      if (!pixel_fits(n)) {
        std::fprintf(stderr,
                     "[RGSS] no memory for %zu bytes of bitmap pixels after a "
                     "full GC\n",
                     n);
        mrb_exc_raise(M, mrb_obj_value(M->nomem_err));
      }
    }
  }
  alloc();
}

// OOM_GC: a full GC for an allocation that failed outside mruby's allocator,
// which retries its own (mrb_realloc_simple): the Wio's operator new. Answers
// whether it collected. Not while LVGL draws (PixelGcHold), before the gem is
// up or after its final (mrb_close), during a sweep, nor inside itself.
extern "C" bool rgss_oom_gc(void) {
  static bool running = false;
  mrb_state* const M = g_pixel_gc_hold ? nullptr : g_pixel_mrb;
  if (!M || running || M->gc.state == MRB_GC_STATE_SWEEP || M->gc.disabled ||
      M->gc.iterating)
    return false;
  running = true;
  pixel_gc(M);
  running = false;
  return true;
}

struct DeferredList;

// LAZY_PIXELS: a `Bitmap.new(w, h)` holds no pixels until something reads or
// draws them; until then every pixel is transparent black. ensure_pixels
// allocates them, and DataType::get, promote_to_direct, bmp_require_shared and
// spr_bind_display call it, so only bmp_raw users see the empty buffer.
struct LazyPixels {};

struct Bitmap {
  static constexpr const char* kTypeName = "Bitmap";
  int32_t width, height;
  // kPixelI8 while the bitmap keeps the palette form it was decoded
  // from: `buffer` then holds one palette index per pixel and `palette` 256
  // B, G, R, A entries. See promote_to_direct for what may touch it then.
  PixelFormat format;
  // The format promote_to_direct expands an indexed bitmap to -- the one the
  // decoder would have produced -- and `format` itself otherwise.
  PixelFormat direct_format;
  std::vector<uint8_t> buffer;
  std::vector<uint8_t> palette;
  // ROM_BITMAP: indices and palette read in place from the game ROM, standing
  // in for an empty `buffer` / `palette`. Readers go through px() and pal().
  const uint8_t* rom_px = nullptr;
  const uint8_t* rom_pal = nullptr;
  // ROM_BITMAP_SOURCE: the source whose entry `rom_index` this bitmap pins
  // while rom_px points into it; release_rom drops the pin.
  const rgss_rom_bitmap_source* rom_src = nullptr;
  uint32_t rom_index = 0;
  // The draws recorded since Bitmap#_defer, which stand in for `buffer` (then
  // empty); null for an ordinary bitmap. See DEFERRED_BITMAP.
  std::shared_ptr<DeferredList> deferred;
  // Set by Bitmap#_defer: a materialized bitmap goes back to recording once a
  // clear or a whole-bitmap fill makes its pixels irrelevant.
  bool wants_defer = false;
  // See LAZY_PIXELS: `buffer` is empty and stands for width x height
  // transparent pixels.
  bool lazy = false;
  // Set whenever `buffer` is mutated so Graphics.update can invalidate the
  // sprites showing this bitmap and have LVGL redraw them. Starts true so the
  // initial contents are painted on the first frame after assignment.
  bool dirty = true;
  // Which of g_bitmap_bytes_decoded/_blank this instance's buffer counts
  // against -- fixed at construction (see the constructor's own `decoded`
  // parameter) and never changed afterward, including across a
  // Bitmap#clone's own reassignment (see operator= below): the category
  // tracks how *this* object came to exist, not what its buffer currently
  // holds.
  bool decoded_from_source;

  Bitmap(mrb_int w, mrb_int h, PixelFormat f, bool decoded = false)
      : width(w),
        height(h),
        format(f),
        direct_format(f),
        decoded_from_source(decoded) {
    const size_t n = w * h * pixel_size(f);
    pixel_alloc(n, [&] { buffer.assign(n, 0); });
    counter() += bytes();
  }

  Bitmap(mrb_int w, mrb_int h, PixelFormat f, LazyPixels)
      : width(w),
        height(h),
        format(f),
        direct_format(f),
        lazy(w > 0 && h > 0),
        decoded_from_source(false) {}

  ~Bitmap() {
    counter() -= bytes();
    release_rom();
  }

  void release_rom() {
    if (rom_src)
      rom_src->release(rom_src->ctx, rom_index);
    rom_src = nullptr;
  }

  bool indexed() const { return format == kPixelI8; }
  const uint8_t* px() const { return rom_px ? rom_px : buffer.data(); }
  const uint8_t* pal() const { return rom_pal ? rom_pal : palette.data(); }
  // Heap bytes only: ROM pixels cost none.
  size_t bytes() const { return buffer.size() + palette.size(); }
  size_t& counter() const {
    return decoded_from_source ? g_bitmap_bytes_decoded : g_bitmap_bytes_blank;
  }

  // Only ever assigned through Bitmap#clone's `dst = src;` (this file's
  // bmp_init_copy): a deep copy of the pixel content, but deliberately
  // *not* of `decoded_from_source` -- `dst` keeps counting against whatever
  // category its own construction already added it to, so this can't leave
  // the two counters out of sync with what was actually added/removed at
  // construction/destruction time. Copy-constructing a Bitmap is never done
  // anywhere in this codebase (every use goes through DataType<Bitmap>'s
  // alloc_obj or this operator=) and is deleted below so a future one
  // can't silently bypass this bookkeeping.
  Bitmap& operator=(const Bitmap& other) {
    if (this == &other)
      return *this;
    std::vector<uint8_t> px;
    pixel_alloc(other.buffer.size(), [&] { px = other.buffer; });
    counter() -= bytes();
    width = other.width;
    height = other.height;
    format = other.format;
    direct_format = other.direct_format;
    buffer.swap(px);
    palette = other.palette;
    release_rom();
    rom_px = other.rom_px;
    rom_pal = other.rom_pal;
    retain_rom(other);
    deferred = other.deferred;
    lazy = other.lazy;
    dirty = other.dirty;
    counter() += bytes();
    return *this;
  }

  Bitmap(const Bitmap&) = delete;

 private:
  // A copy of a sourced bitmap pins the entry again. The entry is pinned by
  // `other`, so it is mapped; should the source refuse anyway, the copy takes
  // the pixels into the heap instead.
  void retain_rom(const Bitmap& other) {
    if (!other.rom_src)
      return;
    rgss_rom_bitmap_view v;
    if (other.rom_src->fetch(other.rom_src->ctx, other.rom_index, &v) ==
        RGSS_ROM_FETCH_OK) {
      rom_src = other.rom_src;
      rom_index = other.rom_index;
      return;
    }
    std::fprintf(stderr,
                 "[RGSS] ROM bitmaps: entry %u is pinned but not mapped; "
                 "copying it into the heap\n",
                 static_cast<unsigned>(other.rom_index));
    const size_t n = static_cast<size_t>(width) * height;
    pixel_alloc(n, [&] { buffer.assign(rom_px, rom_px + n); });
    if (rom_pal)
      palette.assign(rom_pal, rom_pal + 256 * 4);
    rom_px = rom_pal = nullptr;
  }
};

// The RPG2k/RPGXP/RPGVX asset loaders below (bmp_decode_into) are the only
// real "decoded from a source" construction path; every other Bitmap
// (blank buffers, canvases, snapshots, and a clone's own copy) is `blank`.
extern "C" size_t rgss_bitmap_bytes_decoded(void) {
  return g_bitmap_bytes_decoded;
}
extern "C" size_t rgss_bitmap_bytes_blank(void) {
  return g_bitmap_bytes_blank;
}

// Whether decoders keep palette images indexed (see promote_to_direct). On by
// default; RGSS_INDEXED_BITMAPS=0 at build time or in the environment turns it
// off, so every bitmap is decoded straight to direct colour as before.
#ifndef RGSS_INDEXED_BITMAPS
#define RGSS_INDEXED_BITMAPS 1
#endif
static bool indexed_bitmaps_enabled() {
#if RGSS_INDEXED_BITMAPS
  static const bool on = [] {
    const char* e = std::getenv("RGSS_INDEXED_BITMAPS");
    return !(e && std::strcmp(e, "0") == 0);
  }();
  return on;
#else
  return false;
#endif
}

void bmp_read(const Bitmap& b,
              mrb_int x,
              mrb_int y,
              int& r,
              int& g,
              int& bl,
              int& a);

// INDEXED_BITMAP: an indexed bitmap's buffer holds palette indices, so only
// bmp_read and the indexed row paths of the blits may read it, and nothing may
// write it or hand it to LVGL (whose software renderer would expand an I8
// image to a full ARGB copy anyway). Every writer, and anything that hands the
// buffer out, calls this first; bmp_put does too, as the backstop. Replacing
// `buffer` here is safe precisely because an indexed buffer was never handed
// out. `keep` false skips the expansion for a caller about to overwrite every
// pixel.
//
// ROM_BITMAP: so nothing writes or frees a ROM bitmap's pixels: the only way
// out of the indexed form is this copy into the heap, and the palette's only
// in-place writer (hue_change) takes its own copy first (own_palette).
void deferred_materialize(Bitmap& b);

// See LAZY_PIXELS.
void ensure_pixels(Bitmap& b) {
  if (!b.lazy)
    return;
  const size_t n =
      static_cast<size_t>(b.width) * b.height * pixel_size(b.format);
  pixel_alloc(n, [&] { b.buffer.assign(n, 0); });
  b.lazy = false;
  b.counter() += b.bytes();
}

void promote_to_direct(Bitmap& b, bool keep = true) {
  if (b.deferred) {
    deferred_materialize(b);
    return;
  }
  ensure_pixels(b);
  if (!b.indexed())
    return;
  const unsigned bpp = pixel_size(b.direct_format);
  std::vector<uint8_t> out;
  const size_t n = static_cast<size_t>(b.width) * b.height * bpp;
  pixel_alloc(n, [&] { out.assign(n, 0); });
  if (keep) {
    // Palette entries are B, G, R, A: their first `bpp` bytes are the pixel in
    // either direct format.
    const uint8_t* pal = b.pal();
    const uint8_t* s = b.px();
    uint8_t* d = out.data();
    for (size_t i = 0, n = static_cast<size_t>(b.width) * b.height; i < n;
         ++i) {
      std::memcpy(d, pal + s[i] * 4u, bpp);
      d += bpp;
    }
  }
  b.counter() -= b.bytes();
  b.buffer.swap(out);
  std::vector<uint8_t>().swap(b.palette);
  b.rom_px = b.rom_pal = nullptr;
  b.release_rom();
  b.format = b.direct_format;
  b.counter() += b.bytes();
}

// A heap copy of a ROM palette, for the writer that recolours it in place.
static void own_palette(Bitmap& b) {
  if (!b.rom_pal)
    return;
  b.counter() -= b.bytes();
  b.palette.assign(b.rom_pal, b.rom_pal + 256 * 4);
  b.rom_pal = nullptr;
  b.counter() += b.bytes();
}

// Every DataType<T>-wrapped Ruby object is backed by a std::shared_ptr<T>
// rather than a bare T* -- but every real call site in this codebase today
// (alloc_obj/make below, all of them) is, and stays, single-owner: exactly
// one RData ever holds the one shared_ptr for a given T instance, so its
// use-count drops to zero and the T is destroyed the moment that RData is
// GC'd, identical to the old bare-pointer-in-RData behavior. Checked before
// concluding that: grepped this whole file (and, project-wide, everywhere
// else DataType<T> is used -- nowhere else) for anything that would alias
// two RDatas to one T -- Bitmap#clone/Rect#set/Color#set/Tone#set/Table's
// own dup path all *copy* the pointee's *value* into an already-separately-
// owned T (operator=/field-by-field
// copy), never share the pointer itself; `_load`'s own Marshal path always
// builds a brand-new T via `make`, never re-wraps an existing one. So this
// is unique_ptr-with-extra-steps for now, not real multi-owner sharing --
// shared_ptr is the vehicle here only because it's the one smart pointer
// that can be built from an already-in-place-constructed T* with a custom
// (mrb_malloc/mrb_free-based) deleter *and* trivially handed to a second
// owner later without this struct's own API changing, if a genuinely
// sharing call site (e.g. a future non-escaping bc2cpp optimization, or
// some real aliasing use this project doesn't have yet) ever needs one.
//
// RData's own `data` field is a bare void*, so the shared_ptr itself has to
// live in a separate heap box: `data` points at a `new
// std::shared_ptr<T>(...)` (the box), and free_obj's `delete`s it -- that
// only ever drops *this* RData's own reference (immediately destroying the
// underlying T via make_owned's own custom deleter, below, exactly when
// this was the last reference, which today is always, per the above). The T
// object's own storage is still mrb_malloc'd/mrb_freed exactly as before
// (via a shared_ptr custom deleter, not shared_ptr's own make_shared, since
// several T's -- Bitmap in particular -- are neither copyable nor movable,
// so the T has to be placement-new'd directly into its final storage, never
// passed through shared_ptr's own by-value constructor API); only the
// small, fixed-size box and the shared_ptr's own control block use plain
// `new`/`delete` (this project's mruby-rgss always compiles as C++ with
// exceptions enabled -- so an OOM there throwing
// std::bad_alloc is no different from the std::vector allocations Bitmap's
// own pixel buffer already relies on).
template <class T>
inline void settle_for_access(T&) {}
inline void settle_for_access(Bitmap& b) {
  if (b.deferred)
    deferred_materialize(b);
  ensure_pixels(b);
}

template <class T>
struct DataType {
  static void free_obj(mrb_state* M, void* p) {
    (void)M;
    if (!p)
      return;

    delete static_cast<std::shared_ptr<T>*>(p);
  }

  static mrb_data_type data_type;

  // Construct a T in place (mrb_malloc'd storage, exactly like every
  // DataType<T> object always has been) and wrap it in a freshly-owning
  // shared_ptr, freed via mrb_free/destroy_at through a custom deleter --
  // never make_shared, which would require T to be copy/move-constructible
  // from a temporary (Bitmap is neither, see this struct's own top comment).
  template <class... Args>
  static std::shared_ptr<T> make_owned(mrb_state* M, Args... args) {
    void* mem_ptr = mrb_malloc(M, sizeof(T));
    T* ptr;
#if defined(__cpp_exceptions)
    try {
      ptr = new (mem_ptr) T{args...};
    } catch (...) {
      mrb_free(M, mem_ptr);
      throw;
    }
#else
    ptr = new (mem_ptr) T{args...};
#endif
    return std::shared_ptr<T>(ptr, [M](T* p) {
      std::destroy_at(p);
      mrb_free(M, p);
    });
  }

  // Wrap an already-constructed shared_ptr<T> into a brand new RData under
  // class `c`. The vehicle bc2cpp's own devirtualized `Owner.new(...)`
  // construction codegen calls into (tools/bc2cpp/bc2cpp.rb's compile_send,
  // the "MONO :new -> direct native construct" path, and this file's own
  // rgss_*_new_direct entry points below) -- going straight from a compiled
  // method's own already-known argument values to a constructed T and a
  // wrapped RData, instead of dispatching through Class#new/#allocate/
  // #initialize.
  static V make_direct(mrb_state* M, RClass* c, std::shared_ptr<T> ptr) {
    return mrb_obj_value(mrb_data_object_alloc(
        M, c, new std::shared_ptr<T>(std::move(ptr)), &data_type));
  }

  template <class... Args>
  static T& alloc_obj(mrb_state* M, V self, Args... args) {
    mrb_assert(!DATA_PTR(self));
    std::shared_ptr<T> owned = make_owned(M, args...);
    T& ref = *owned;
    mrb_data_init(self, new std::shared_ptr<T>(std::move(owned)), &data_type);
    return ref;
  }

  // Allocate a brand new instance of class `c` wrapping a freshly constructed
  // T. Used by the Marshal `_load` class methods which receive the class and
  // must return a populated object.
  template <class... Args>
  static V make(mrb_state* M, RClass* c, Args... args) {
    return make_direct(M, c, make_owned(M, args...));
  }

  // The object as stored: a deferred Bitmap stays deferred (see
  // DEFERRED_BITMAP). `get` is what everything else uses.
  static T& raw(mrb_state* M, V self) {
    return **reinterpret_cast<std::shared_ptr<T>*>(
        mrb_data_get_ptr(M, self, &data_type));
  }

  static T& get(mrb_state* M, V self) {
    T& t = raw(M, self);
    settle_for_access(t);
    return t;
  }
};

template <class T>
mrb_data_type DataType<T>::data_type{
    T::kTypeName,
    &DataType<T>::free_obj,
};

// Generic floating point component getter/setter usable by Color and Tone.
template <class T, double T::* Field>
mrb_value component_get(mrb_state* M, V self) {
  return rgss::num_value(M, DataType<T>::get(M, self).*Field);
}

template <class T, double T::* Field, int Lo, int Hi>
mrb_value component_set(mrb_state* M, V self) {
  mrb_value vv;
  mrb_get_args(M, "o", &vv);
  double v = rgss::num_arg(M, vv);
  if (v < Lo)
    v = Lo;
  if (v > Hi)
    v = Hi;
  DataType<T>::get(M, self).*Field = v;
  return rgss::num_value(M, v);
}

std::string pack_doubles(std::initializer_list<double> vals) {
  std::string s;
  s.reserve(vals.size() * sizeof(double));
  for (double v : vals) {
    char buf[sizeof(double)];
    std::memcpy(buf, &v, sizeof(double));
    s.append(buf, sizeof(double));
  }
  return s;
}

void unpack_doubles(const char* p, mrb_int len, double* out, int n) {
  for (int i = 0; i < n; ++i) {
    if ((mrb_int)((i + 1) * sizeof(double)) <= len)
      std::memcpy(&out[i], p + i * sizeof(double), sizeof(double));
  }
}

// ---- Color ----------------------------------------------------------------

mrb_value color_init(mrb_state* M, V self) {
  mrb_value rv = mrb_fixnum_value(0), gv = mrb_fixnum_value(0),
            bv = mrb_fixnum_value(0), av = mrb_fixnum_value(255);
  mrb_get_args(M, "|oooo", &rv, &gv, &bv, &av);
  Color& c = DataType<Color>::alloc_obj(M, self);
  c.red = clamp255(rgss::num_arg(M, rv));
  c.green = clamp255(rgss::num_arg(M, gv));
  c.blue = clamp255(rgss::num_arg(M, bv));
  c.alpha = clamp255(rgss::num_arg(M, av));
  return self;
}

mrb_value color_set(mrb_state* M, V self) {
  Color& c = DataType<Color>::get(M, self);
  if (mrb_get_argc(M) == 1) {
    V o;
    mrb_get_args(M, "o", &o);
    c = DataType<Color>::get(M, o);
  } else {
    mrb_value rv, gv, bv, av = mrb_fixnum_value(255);
    mrb_get_args(M, "ooo|o", &rv, &gv, &bv, &av);
    c.red = clamp255(rgss::num_arg(M, rv));
    c.green = clamp255(rgss::num_arg(M, gv));
    c.blue = clamp255(rgss::num_arg(M, bv));
    c.alpha = clamp255(rgss::num_arg(M, av));
  }
  return self;
}

mrb_value color_eq_native_body(mrb_state* M, V self, mrb_value o) {
  if (!mrb_obj_is_kind_of(M, o, mrb_class(M, self)))
    return mrb_false_value();
  Color& a = DataType<Color>::get(M, self);
  Color& b = DataType<Color>::get(M, o);
  return mrb_bool_value(a.red == b.red && a.green == b.green &&
                        a.blue == b.blue && a.alpha == b.alpha);
}

mrb_value color_eq(mrb_state* M, V self) {
  V o;
  mrb_get_args(M, "o", &o);
  return color_eq_native_body(M, self, o);
}

mrb_value color_to_s(mrb_state* M, V self) {
  Color& c = DataType<Color>::get(M, self);
  char buf[128];
  std::snprintf(buf, sizeof(buf), "(%g, %g, %g, %g)", c.red, c.green, c.blue,
                c.alpha);
  return mrb_str_new_cstr(M, buf);
}

mrb_value color_dump(mrb_state* M, V self) {
  Color& c = DataType<Color>::get(M, self);
  std::string s = pack_doubles({c.red, c.green, c.blue, c.alpha});
  return mrb_str_new(M, s.data(), s.size());
}

mrb_value color_load_native_body(mrb_state* M,
                                 V self,
                                 const char* p,
                                 mrb_int len) {
  double d[4] = {0, 0, 0, 255};
  unpack_doubles(p, len, d, 4);
  V obj = DataType<Color>::make(M, mrb_class_ptr(self));
  Color& c = DataType<Color>::get(M, obj);
  c.red = d[0];
  c.green = d[1];
  c.blue = d[2];
  c.alpha = d[3];
  return obj;
}

mrb_value color_load(mrb_state* M, V self) {
  const char* p;
  mrb_int len;
  mrb_get_args(M, "s", &p, &len);
  return color_load_native_body(M, self, p, len);
}

// ---- Tone -----------------------------------------------------------------

mrb_value tone_init(mrb_state* M, V self) {
  mrb_value rv = mrb_fixnum_value(0), gv = mrb_fixnum_value(0),
            bv = mrb_fixnum_value(0), grv = mrb_fixnum_value(0);
  mrb_get_args(M, "|oooo", &rv, &gv, &bv, &grv);
  Tone& t = DataType<Tone>::alloc_obj(M, self);
  t.red = clamp_signed255(rgss::num_arg(M, rv));
  t.green = clamp_signed255(rgss::num_arg(M, gv));
  t.blue = clamp_signed255(rgss::num_arg(M, bv));
  t.gray = clamp255(rgss::num_arg(M, grv));
  return self;
}

mrb_value tone_set(mrb_state* M, V self) {
  Tone& t = DataType<Tone>::get(M, self);
  if (mrb_get_argc(M) == 1) {
    V o;
    mrb_get_args(M, "o", &o);
    t = DataType<Tone>::get(M, o);
  } else {
    mrb_value rv, gv, bv, grv = mrb_fixnum_value(0);
    mrb_get_args(M, "ooo|o", &rv, &gv, &bv, &grv);
    t.red = clamp_signed255(rgss::num_arg(M, rv));
    t.green = clamp_signed255(rgss::num_arg(M, gv));
    t.blue = clamp_signed255(rgss::num_arg(M, bv));
    t.gray = clamp255(rgss::num_arg(M, grv));
  }
  return self;
}

mrb_value tone_eq_native_body(mrb_state* M, V self, mrb_value o) {
  if (!mrb_obj_is_kind_of(M, o, mrb_class(M, self)))
    return mrb_false_value();
  Tone& a = DataType<Tone>::get(M, self);
  Tone& b = DataType<Tone>::get(M, o);
  return mrb_bool_value(a.red == b.red && a.green == b.green &&
                        a.blue == b.blue && a.gray == b.gray);
}

mrb_value tone_eq(mrb_state* M, V self) {
  V o;
  mrb_get_args(M, "o", &o);
  return tone_eq_native_body(M, self, o);
}

mrb_value tone_to_s(mrb_state* M, V self) {
  Tone& t = DataType<Tone>::get(M, self);
  char buf[128];
  std::snprintf(buf, sizeof(buf), "(%g, %g, %g, %g)", t.red, t.green, t.blue,
                t.gray);
  return mrb_str_new_cstr(M, buf);
}

mrb_value tone_dump(mrb_state* M, V self) {
  Tone& t = DataType<Tone>::get(M, self);
  std::string s = pack_doubles({t.red, t.green, t.blue, t.gray});
  return mrb_str_new(M, s.data(), s.size());
}

mrb_value tone_load_native_body(mrb_state* M,
                                V self,
                                const char* p,
                                mrb_int len) {
  double d[4] = {0, 0, 0, 0};
  unpack_doubles(p, len, d, 4);
  V obj = DataType<Tone>::make(M, mrb_class_ptr(self));
  Tone& t = DataType<Tone>::get(M, obj);
  t.red = d[0];
  t.green = d[1];
  t.blue = d[2];
  t.gray = d[3];
  return obj;
}

mrb_value tone_load(mrb_state* M, V self) {
  const char* p;
  mrb_int len;
  mrb_get_args(M, "s", &p, &len);
  return tone_load_native_body(M, self, p, len);
}

// ---- bc2cpp devirtualized-construction entry points ------------------------

namespace {
// Captured once, at gem-init time (mrb_mruby_rgss_gem_init/define_rect
// below, right after each RClass* is actually created), for bc2cpp's own
// devirtualized `.new` construction guard (tools/bc2cpp/bc2cpp.rb's
// compile_send, NATIVE_CONSTRUCT_TARGETS). Deliberately NOT a second
// mrb_const_get/mrb_class_get_under lookup of "RGSS::Rect"/"Color"/"Tone"
// -- that would just observe whatever the constant currently names,
// exactly what a reassignment (`RGSS::Tone = SomeOtherClass`) would
// already have changed, so it could never actually detect one happened.
// This is the real RClass* this gem's own gem_init created, independent
// of whatever the constant table says right now.
//
// A plain global (not keyed per-mrb_state) is safe here: every real
// mrb_open() call site in this project (src/main.cxx, app/psp/main.cxx,
// app/wio's own SD-card smoke-test binary) opens and uses exactly one
// mrb_state at a time, never two concurrently -- confirmed by grepping
// every mrb_open() call site in this project. A fresh
// mrb_mruby_rgss_gem_init call (a fresh VM) simply overwrites these for
// that VM's own lifetime, same as this file's own g_bitmap_bytes_decoded/
// _blank pair already does for a different fact.
RClass* g_native_rect_class = nullptr;
RClass* g_native_color_class = nullptr;
RClass* g_native_tone_class = nullptr;
RClass* g_native_sprite_class = nullptr;
RClass* g_native_bitmap_class = nullptr;
RClass* g_native_table_class = nullptr;
RClass* g_native_window_class = nullptr;
RClass* g_native_viewport_class = nullptr;
RClass* g_native_plane_class = nullptr;
RClass* g_native_tilemap_class = nullptr;
}  // namespace

// The bc2cpp direct-construct entry points (rgss::rect/color/tone/sprite/
// bitmap_new_direct + rgss::native_*_class, declared in include/
// rgss_construct.hxx) live in namespace `rgss` at file scope, next to
// `bitmap_pixels` below -- plain C++ linkage reaches every translation
// unit that includes the header, so no `extern "C"` escape hatch is
// needed (that was only ever required because these used to sit inside
// this file's own top-level anonymous namespace). The RClass* globals
// above stay TU-local: only lib.cxx itself ever writes them. The
// definitions need file-scope helpers (DataType<T>, clamp255,
// spr_init/parent_object/wrap_node/register_zobj), all visible at file
// scope within this same translation unit.

// Called directly by bc2cpp's own generated code (compile_send's "MONO :new
// -> direct native construct" path) in place of Class#new's own
// allocate+initialize dispatch, when a compiled `.new` call site's receiver
// is provably (GETCONST-traced) exactly one of Rect/Color/Tone/Sprite/
// Bitmap -- see
// NATIVE_CONSTRUCT_TARGETS there for the whole-program side of this.
//
// Unwrapped (native C++ typed) parameters, not mrb_value -- the first step
// of a deliberately incremental move away from mrb_value at bc2cpp's own
// generated call sites (starting here, at construction, since these three
// functions already assumed a fixed, known native type per field long
// before this change; a broader per-argument type-directed calling
// convention for ordinary compiled methods is a separate, much larger
// follow-up, not attempted here). The generated call site itself now does
// exactly the same mrb_as_int/mrb_as_float unboxing mrb_get_args' own "i"/
// "f" format specifiers do internally (3rd/mruby/src/class.c) -- see
// compile_send's own comment -- so a devirtualized `Tone.new(x)` still
// observes identical coercion, and identical TypeError-raising for a bad
// `x`, to the ordinary #initialize dispatch it replaces; moving those same
// mrb_as_int/mrb_as_float calls from here to the call site changes nothing
// observable (mrb_state* M's own exception handling has no notion of a
// calling-frame boundary to cross), only which translation unit's own text
// spells them out. `klass` is `RClass*` for the identical reason: the
// caller already computed `mrb_class_ptr(recv)` for its own runtime
// class-identity guard (see compile_send's own comment on why that check
// exists), so passing that same pointer straight through avoids a second,
// redundant `mrb_class_ptr` call here for no behavioral difference.
//
// Rect has no clamping at all (plain ints, straight through). Color/Tone
// apply the exact same clamp255/clamp_signed255 calls their own
// #initialize (color_init/tone_init above) already does -- not a second
// copy of that logic that could drift, just the same two free functions
// called again in the same field order. (Bodies live in namespace `rgss`
// at file scope, below, declared in include/rgss_construct.hxx.)

// Sprite's own forward declaration lived here too (it delegated to
// `spr_init`, defined further below) -- moved down there with it, same
// reason, one home for all four.

// ---- Table ----------------------------------------------------------------

long table_index(const Table& t, mrb_int x, mrb_int y, mrb_int z) {
  if (x < 0 || x >= t.xsize || y < 0 || y >= t.ysize || z < 0 || z >= t.zsize)
    return -1;
  return x + y * (long)t.xsize + z * (long)t.xsize * t.ysize;
}

void table_initialize_fields(Table& t,
                             mrb_int argc,
                             mrb_int a,
                             mrb_int b,
                             mrb_int c) {
  t.dim = argc;
  t.xsize = a;
  t.ysize = argc >= 2 ? b : 1;
  t.zsize = argc >= 3 ? c : 1;
  t.data.assign((size_t)t.xsize * t.ysize * t.zsize, 0);
}

mrb_value table_init(mrb_state* M, V self) {
  mrb_int a, b = 1, c = 1;
  mrb_get_args(M, "i|ii", &a, &b, &c);
  mrb_int argc = mrb_get_argc(M);
  Table& t = DataType<Table>::alloc_obj(M, self);
  table_initialize_fields(t, argc, a, b, c);
  return self;
}

// RGSS's value types are copied with #clone / #dup throughout a game's own
// scripts — `@tone_target = tone.clone` in Game_Screen, `@flash_color =
// color.clone`, Game_Map's fog tone, Game_Picture's. mruby's clone/dup allocate
// a bare object of the same class and copy only its instance variables, so the
// copy came back with no native payload at all and the first read of it raised
// "uninitialized RGSS::Tone" — which is where Pray for You stopped once it
// reached its map and the screen tone started moving. Both clone and dup call
// initialize_copy on the new object, so this is where the payload is copied.
template <class T>
mrb_value data_init_copy(mrb_state* M, V self) {
  V other;
  mrb_get_args(M, "o", &other);
  if (mrb_obj_equal(M, self, other))
    return self;
  const T& src = DataType<T>::get(M, other);
  if (DATA_PTR(self))
    DataType<T>::get(M, self) = src;
  else
    DataType<T>::alloc_obj(M, self) = src;
  return self;
}

// Table#[] after the arguments are read; also rgss_table_aref_impl, the entry
// bc2cpp's closed index helper calls with its own arguments.
mrb_value table_get_impl(mrb_state* M,
                         V self,
                         mrb_int x,
                         mrb_int y,
                         mrb_int z) {
  Table& t = DataType<Table>::get(M, self);
  long i = table_index(t, x, y, z);
  if (i < 0)
    return mrb_nil_value();
  return mrb_fixnum_value(t.data[i]);
}

mrb_value table_get(mrb_state* M, V self) {
  mrb_int x, y = 0, z = 0;
  mrb_get_args(M, "i|ii", &x, &y, &z);
  return table_get_impl(M, self, x, y, z);
}

// A write outside the table is dropped, and the value is only converted once it
// is going to be stored. The order matters, because a game's own scripts lean
// on it: Pray for You's `map_light` walks `for x in 0..(self.width)` —
// inclusive, so one past the edge — and does `@passages_data[x, y] |= 0x0f`. At
// the edge the read answers nil, `nil | 0x0f` is `true`, and that `true` comes
// back here as the value of a write RGSS was always going to ignore. Converting
// the arguments up front (mrb_get_args "ii|ii") raised "TypeError: true cannot
// be converted to Integer" instead, which killed the game on New Game. An
// *in-range* write of a non-Integer still raises, as it should.
mrb_value table_set_impl(mrb_state* M,
                         V self,
                         mrb_int argc,
                         mrb_value a0,
                         mrb_value a1,
                         mrb_value a2,
                         mrb_value a3) {
  mrb_int x = mrb_as_int(M, a0), y = 0, z = 0;
  mrb_value v;
  if (argc == 2) {
    v = a1;
  } else if (argc == 3) {
    y = mrb_as_int(M, a1);
    v = a2;
  } else {
    y = mrb_as_int(M, a1);
    z = mrb_as_int(M, a2);
    v = a3;
  }
  Table& t = DataType<Table>::get(M, self);
  const long i = table_index(t, x, y, z);
  if (i < 0)
    return v;
  t.data[i] = (int16_t)mrb_as_int(M, v);
  return v;
}

mrb_value table_set(mrb_state* M, V self) {
  mrb_value a0, a1, a2 = mrb_nil_value(), a3 = mrb_nil_value();
  mrb_get_args(M, "oo|oo", &a0, &a1, &a2, &a3);
  return table_set_impl(M, self, mrb_get_argc(M), a0, a1, a2, a3);
}

mrb_value table_resize(mrb_state* M, V self) {
  mrb_int a, b = 1, c = 1;
  mrb_get_args(M, "i|ii", &a, &b, &c);
  mrb_int argc = mrb_get_argc(M);
  Table& t = DataType<Table>::get(M, self);
  int32_t nx = a, ny = argc >= 2 ? b : 1, nz = argc >= 3 ? c : 1;
  std::vector<int16_t> nd((size_t)nx * ny * nz, 0);
  for (int32_t z = 0; z < std::min(nz, t.zsize); ++z)
    for (int32_t y = 0; y < std::min(ny, t.ysize); ++y)
      for (int32_t x = 0; x < std::min(nx, t.xsize); ++x)
        nd[x + y * (long)nx + z * (long)nx * ny] =
            t.data[x + y * (long)t.xsize + z * (long)t.xsize * t.ysize];
  t.dim = argc;
  t.xsize = nx;
  t.ysize = ny;
  t.zsize = nz;
  t.data = std::move(nd);
  return self;
}

mrb_value table_dump(mrb_state* M, V self) {
  Table& t = DataType<Table>::get(M, self);
  std::string s;
  auto put32 = [&s](uint32_t v) {
    char b[4];
    std::memcpy(b, &v, 4);
    s.append(b, 4);
  };
  put32(t.dim);
  put32(t.xsize);
  put32(t.ysize);
  put32(t.zsize);
  put32((uint32_t)t.data.size());
  for (int16_t v : t.data) {
    char b[2];
    std::memcpy(b, &v, 2);
    s.append(b, 2);
  }
  return mrb_str_new(M, s.data(), s.size());
}

mrb_value table_load_native_body(mrb_state* M,
                                 V self,
                                 const char* p,
                                 mrb_int len) {
  auto get32 = [p, len](mrb_int off) -> uint32_t {
    uint32_t v = 0;
    if (off + 4 <= len)
      std::memcpy(&v, p + off, 4);
    return v;
  };
  V obj = DataType<Table>::make(M, mrb_class_ptr(self));
  Table& t = DataType<Table>::get(M, obj);
  t.dim = get32(0);
  t.xsize = get32(4);
  t.ysize = get32(8);
  t.zsize = get32(12);
  uint32_t count = get32(16);
  t.data.assign(count, 0);
  for (uint32_t i = 0; i < count; ++i) {
    int16_t v = 0;
    mrb_int off = 20 + (mrb_int)i * 2;
    if (off + 2 <= len)
      std::memcpy(&v, p + off, 2);
    t.data[i] = v;
  }
  return obj;
}

mrb_value table_load(mrb_state* M, V self) {
  const char* p;
  mrb_int len;
  mrb_get_args(M, "s", &p, &len);
  return table_load_native_body(M, self, p, len);
}

// ---- Bitmap ---------------------------------------------------------------

// Human-readable diagnostic for the most recent Bitmap load that reached (and
// failed inside) a real decoder. Exposed to Ruby via `Bitmap._load_error` so a
// failed windowskin/graphic load can report exactly which decoder gave up and
// why -- e.g. stb's "bad dist" on a corrupt/non-standard XYZ zlib stream --
// instead of a bare "Failed to init bitmap". Left untouched by plain
// file-not-found probes so the informative message survives the loader's
// subsequent extension attempts.
static std::string g_bitmap_load_error;

// Whether any decoder was handed bytes at all since the current Bitmap load
// began. Both diagnostics above are *globals that survive a failed load*: stb
// keeps its failure reason until the next decode sets one, and
// g_bitmap_load_error until the next decoder fails. A name that matched no file
// anywhere -- the RTP asset a released game references but does not pack --
// runs no decoder, so reporting either of them attributes some earlier file's
// error to it. Worse, stb's reason after *any* successful PNG is "no SOI": both
// stbi__load_main and stbi__info_main try JPEG first, and its header check
// fails on a PNG's magic without clearing the reason on the PNG's later
// success. Every missing asset in a PNG game therefore came out as
// "(no SOI)" -- a JPEG complaint about a file that was never opened. This flag
// lets the Ruby loader say "not found" instead. Reset per load by
// `Bitmap._begin_load`, read back through `Bitmap._decoder_ran?`.
static bool g_bitmap_decoder_ran = false;

static void set_bitmap_load_error(const char* fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  std::vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  g_bitmap_load_error = buf;
}

// xyz_inflate, png_tol and the indexed decoders (INDEXED_BITMAP).
#include "rgss_indexed_decode.hxx"

// An XYZ image as a freshly stb-allocated buffer (free with stbi_image_free)
// of width*height*4 bytes in LVGL's B, G, R, A byte order, setting *w/*h/*c.
// When `trans` is set the first palette entry is treated as the transparent
// colour, matching stb's transparent-palette handling for PNGs.
static uint8_t* load_xyz_mem(const uint8_t* data,
                             size_t sz,
                             const char* label,
                             int* w,
                             int* h,
                             int* c,
                             bool trans) {
  int width = 0, height = 0;
  char* raw = xyz_inflate(data, sz, label, &width, &height);
  if (!raw)
    return nullptr;
  const uint8_t* pal = reinterpret_cast<const uint8_t*>(raw);
  const uint8_t* idx = pal + 768;

  uint8_t* out = (uint8_t*)stbi__malloc((size_t)width * height * 4);
  if (!out) {
    stbi_image_free(raw);
    return nullptr;
  }
  for (int i = 0; i < width * height; ++i) {
    const uint8_t p = idx[i];
    out[i * 4 + 0] = pal[p * 3 + 2];               // B
    out[i * 4 + 1] = pal[p * 3 + 1];               // G
    out[i * 4 + 2] = pal[p * 3 + 0];               // R
    out[i * 4 + 3] = (trans && p == 0) ? 0 : 255;  // A
  }
  stbi_image_free(raw);
  *w = width;
  *h = height;
  *c = 4;
  return out;
}

// Decode `d` as a PNG using the tolerant inflater above. Returns a freshly
// stb-allocated (free with stbi_image_free) width*height*4 B, G, R, A buffer
// and sets *w/*h/*c, or nullptr when the bytes are not a PNG this fallback
// handles (non-interlaced; bit depth 8, or indexed 1/2/4). `trans` maps palette
// index 0 to transparent, matching the primary loader's colour-key handling.
//
// Takes the bytes rather than a path, like load_xyz_mem above, so an entry read
// out of an encrypted RGSSAD archive gets the same fallback a loose file does;
// `label` only names the source in the diagnostics.
static uint8_t* load_png_tolerant_mem(const uint8_t* d,
                                      size_t sz,
                                      const char* label,
                                      int* wout,
                                      int* hout,
                                      int* c,
                                      bool trans) {
  static const uint8_t sig[8] = {0x89, 0x50, 0x4e, 0x47,
                                 0x0d, 0x0a, 0x1a, 0x0a};
  if (sz < 8 || std::memcmp(d, sig, 8) != 0)
    return nullptr;

  int w = 0, h = 0, depth = 0, ct = 0, interlace = 0;
  std::vector<uint8_t> idat, plte, trns;
  size_t i = 8;
  while (i + 8 <= sz) {
    const uint32_t len = png_tol::be32(d + i);
    const uint8_t* typ = d + i + 4;
    const uint8_t* body = d + i + 8;
    if (i + 12 + len > sz)
      break;
    if (!std::memcmp(typ, "IHDR", 4) && len >= 13) {
      w = (int)png_tol::be32(body);
      h = (int)png_tol::be32(body + 4);
      depth = body[8];
      ct = body[9];
      interlace = body[12];
    } else if (!std::memcmp(typ, "IDAT", 4)) {
      idat.insert(idat.end(), body, body + len);
    } else if (!std::memcmp(typ, "PLTE", 4)) {
      plte.assign(body, body + len);
    } else if (!std::memcmp(typ, "tRNS", 4)) {
      trns.assign(body, body + len);
    } else if (!std::memcmp(typ, "IEND", 4)) {
      break;
    }
    i += 12 + len;
  }
  if (w <= 0 || h <= 0 || interlace != 0)
    return nullptr;
  if (depth != 8 && !(ct == 3 && (depth == 1 || depth == 2 || depth == 4)))
    return nullptr;
  int channels;
  switch (ct) {
    case 0:
      channels = 1;
      break;
    case 2:
      channels = 3;
      break;
    case 3:
      channels = 1;
      break;
    case 4:
      channels = 2;
      break;
    case 6:
      channels = 4;
      break;
    default:
      return nullptr;
  }
  if (ct == 3 && plte.size() < 3)
    return nullptr;

  const size_t rowbytes = ((size_t)w * channels * depth + 7) / 8;
  int bpp = (channels * depth + 7) / 8;
  if (bpp < 1)
    bpp = 1;
  std::vector<uint8_t> filt((rowbytes + 1) * (size_t)h, 0);
  const long need = (long)((rowbytes + 1) * (size_t)h);
  if (png_tol::inflate_tolerant(idat.data(), idat.size(), filt) < need) {
    set_bitmap_load_error(
        "PNG %dx%d depth %d colortype %d '%s': tolerant inflate produced too "
        "little data",
        w, h, depth, ct, label);
    return nullptr;
  }

  std::vector<uint8_t> raw;
  png_tol::unfilter(filt.data(), rowbytes, bpp, h, raw);

  uint8_t* out = (uint8_t*)stbi__malloc((size_t)w * h * 4);
  if (!out)
    return nullptr;
  auto set = [&](int px, int R, int G, int B, int A) {
    out[px * 4 + 0] = (uint8_t)B;
    out[px * 4 + 1] = (uint8_t)G;
    out[px * 4 + 2] = (uint8_t)R;
    out[px * 4 + 3] = (uint8_t)A;
  };
  const int palcount = (int)(plte.size() / 3);
  for (int y = 0; y < h; y++) {
    const uint8_t* row = &raw[(size_t)rowbytes * y];
    for (int x = 0; x < w; x++) {
      const int px = y * w + x;
      if (ct == 3) {
        int idx;
        if (depth == 8) {
          idx = row[x];
        } else {
          const int per = 8 / depth;
          const int shift = (per - 1 - (x % per)) * depth;
          idx = (row[x / per] >> shift) & ((1 << depth) - 1);
        }
        if (idx >= palcount)
          idx = palcount ? palcount - 1 : 0;
        int A = 255;
        if (trans && idx == 0)
          A = 0;
        if ((size_t)idx < trns.size())
          A = trns[idx];
        set(px, plte[idx * 3], plte[idx * 3 + 1], plte[idx * 3 + 2], A);
      } else if (ct == 2) {
        set(px, row[x * 3], row[x * 3 + 1], row[x * 3 + 2], 255);
      } else if (ct == 6) {
        set(px, row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]);
      } else if (ct == 0) {
        const int g = row[x];
        set(px, g, g, g, 255);
      } else {  // ct == 4, grayscale + alpha
        const int g = row[x * 2];
        set(px, g, g, g, row[x * 2 + 1]);
      }
    }
  }
  *wout = w;
  *hout = h;
  *c = 4;
  return out;
}

// Ruby: Bitmap._load_error -> the detailed diagnostic set by the last decoder
// that opened a file and failed inside it (see g_bitmap_load_error).
mrb_value bmp_load_error(mrb_state* M, V self) {
  (void)self;
  return mrb_str_new_cstr(M, g_bitmap_load_error.c_str());
}

// Ruby: Bitmap._stbi_error -> stb_image's raw failure reason for the most
// recent decode attempt (e.g. "bad dist", "unknown image type"). Only
// meaningful when `_decoder_ran?` says this load reached a decoder; stb never
// clears it, so otherwise it is whatever some earlier image left behind.
mrb_value bmp_stbi_error(mrb_state* M, V self) {
  (void)self;
  const char* r = stbi_failure_reason();
  return mrb_str_new_cstr(M, r ? r : "");
}

// Ruby: Bitmap._begin_load -> nil. Drops the diagnostics left by whatever
// loaded last, so a failure reports this load's reason or none at all. Called
// once per Bitmap#initialize, before the candidate search -- not per candidate,
// which would throw away the very message a failed decode is trying to report
// while the loader goes on to try the remaining extensions.
mrb_value bmp_begin_load(mrb_state* M, V self) {
  (void)M;
  (void)self;
  g_bitmap_load_error.clear();
  g_bitmap_decoder_ran = false;
  return mrb_nil_value();
}

// Ruby: Bitmap._decoder_ran? -> whether any bytes reached a decoder since
// `_begin_load` (see g_bitmap_decoder_ran).
mrb_value bmp_decoder_ran(mrb_state* M, V self) {
  (void)M;
  (void)self;
  return mrb_bool_value(g_bitmap_decoder_ran);
}

mrb_value bmp_init_size_native_body(mrb_state* M,
                                    mrb_value self,
                                    mrb_int w,
                                    mrb_int h) {
  DataType<Bitmap>::alloc_obj(M, self, w, h, kPixelARGB8888, LazyPixels{});
  return self;
}

mrb_value bmp_init_size(mrb_state* M, mrb_value self) {
  mrb_int w, h;
  mrb_get_args(M, "ii", &w, &h);
  return bmp_init_size_native_body(M, self, w, h);
}

// RGSS's own RPG::Cache clones a cached bitmap before recolouring it:
//
//     @cache[key] = @cache[path].clone
//     @cache[key].hue_change(hue)
//
// so the plain and hue-rotated variants of a charset share one decode of the
// file. mruby's clone/dup copy the instance variables and then call
// initialize_copy, which for a data object is the only place the native payload
// can be copied -- without this the copy carried no pixels at all and the first
// use of it raised "uninitialized RGSS::Bitmap", which is why RPG::Cache here
// used to load the file a second time instead.
//
// The pixels are *copied*, not shared, and that is the whole point: hue_change
// rewrites the buffer in place, so a shallow copy would have recoloured the
// cache's original along with the variant. The copy starts dirty so anything
// already showing it repaints, and gets its own Font, so setting a size or
// colour on the clone cannot reach back into the bitmap it came from.
#if !defined(WIO_TERMINAL)  // dead weight on wio: no Ruby path reaches it
mrb_value bmp_init_copy_native_body(mrb_state* M, V self, mrb_value other) {
  if (mrb_obj_equal(M, self, other))
    return self;
  const Bitmap& src = DataType<Bitmap>::get(M, other);
  Bitmap& dst = DATA_PTR(self)
                    ? DataType<Bitmap>::get(M, self)
                    : DataType<Bitmap>::alloc_obj(M, self, src.width,
                                                  src.height, src.format);
  dst = src;
  dst.dirty = true;

  const mrb_sym font_iv = MRB_IVSYM(font);
  const V font = mrb_iv_get(M, self, font_iv);
  if (!mrb_nil_p(font)) {
    // Font defines no dup: while Kernel#dup (kernel.c's mrb_obj_dup) answers
    // it, call that function; a script's own Font#dup is still called.
    struct RClass* fc = mrb_class(M, font);
    const mrb_method_t dup = mrb_method_search_vm(M, &fc, MRB_SYM(dup));
    const bool kernel_dup = !MRB_METHOD_UNDEF_P(dup) &&
                            MRB_METHOD_FUNC_P(dup) &&
                            MRB_METHOD_FUNC(dup) == mrb_obj_dup;
    mrb_iv_set(M, self, font_iv,
               kernel_dup ? mrb_obj_dup(M, font)
                          : mrb_funcall_id(M, font, MRB_SYM(dup), 0));
  }
  return self;
}

mrb_value bmp_init_copy(mrb_state* M, V self) {
  V other;
  mrb_get_args(M, "o", &other);
  return bmp_init_copy_native_body(M, self, other);
}
#endif  // !defined(WIO_TERMINAL)

// One frame of RGSS's Graphics.transition(duration, filename, vague) with a
// transition *graphic*: a greyscale image whose brightness at each pixel says
// when that pixel gives way to the new screen. Dark areas go first, light ones
// last, and `vague` is how soft the boundary between the two is -- which is how
// a game gets a spiral wipe, a shatter, or the pentagram RMXP ships as its
// default battle transition, instead of a flat fade.
//
// `self` is the frozen frame (Graphics.freeze's snapshot, which the transition
// draws over the new screen); this rewrites its **alpha** so it dissolves in
// the shape of the map, and the caller shows it through an ordinary Sprite. Per
// pixel, with t the map's brightness and prog the frame's progress, both 0..1:
//
//     keep = clamp((t - prog) / vague, 0, 1)
//
// which is the same expression the shader-based players evaluate on the GPU;
// there is no shader here, so it runs over the buffer once per frame. `keep`
// only ever falls as prog advances, so the snapshot can be rewritten in place.
// A `vague` of 0 is the hard-edged wipe RGSS gives that argument.
//
// The map is sampled nearest-neighbour, so a transition graphic that is not the
// screen's size still covers it (RGSS's own are 640x480, but community ones are
// not always). Greyscale means any one channel will do; red, as the shader
// players read.
mrb_value bmp_transition_alpha_native_body(mrb_state* M,
                                           V self,
                                           mrb_value map_v,
                                           double prog,
                                           double vague) {
  Bitmap& dst = DataType<Bitmap>::get(M, self);
  const Bitmap& map = DataType<Bitmap>::get(M, map_v);
  promote_to_direct(dst);
  const unsigned bpp = pixel_size(dst.format);
  const unsigned map_bpp = pixel_size(map.direct_format);
  // Without an alpha channel on the still there is nothing to dissolve, and
  // without colour channels on the map there is no brightness to read. Either
  // way the caller's plain fade is a better answer than a no-op.
  if (bpp < 4 || map_bpp < 3 || dst.width <= 0 || dst.height <= 0 ||
      map.width <= 0 || map.height <= 0)
    return mrb_false_value();
  for (int32_t y = 0; y < dst.height; ++y) {
    const int32_t my =
        static_cast<int32_t>(static_cast<int64_t>(y) * map.height / dst.height);
    uint8_t* row = dst.buffer.data() + static_cast<size_t>(y) * dst.width * bpp;
    for (int32_t x = 0; x < dst.width; ++x) {
      const int32_t mx =
          static_cast<int32_t>(static_cast<int64_t>(x) * map.width / dst.width);
      int mr, mg, mb, ma;
      bmp_read(map, mx, my, mr, mg, mb, ma);
      const double t = mr / 255.0;
      double keep = vague <= 0.0 ? (t > prog ? 1.0 : 0.0) : (t - prog) / vague;
      if (keep < 0.0)
        keep = 0.0;
      else if (keep > 1.0)
        keep = 1.0;
      row[static_cast<size_t>(x) * bpp + 3] =
          static_cast<uint8_t>(keep * 255.0 + 0.5);
    }
  }
  dst.dirty = true;
  return mrb_true_value();
}

mrb_value bmp_transition_alpha(mrb_state* M, V self) {
  V map_v;
  mrb_value prog_v, vague_v;
  mrb_get_args(M, "ooo", &map_v, &prog_v, &vague_v);
  return bmp_transition_alpha_native_body(M, self, map_v,
                                          rgss::fraction_arg(M, prog_v),
                                          rgss::fraction_arg(M, vague_v));
}

// Read a whole file. Answers false when it cannot be opened or read fully, so
// the caller can fall through to the next candidate path in silence.
static bool slurp_file(const char* f, std::vector<uint8_t>& out) {
  std::FILE* fp = std::fopen(f, "rb");
  if (!fp)
    return false;
  std::fseek(fp, 0, SEEK_END);
  const long sz = std::ftell(fp);
  std::fseek(fp, 0, SEEK_SET);
  if (sz <= 0) {
    std::fclose(fp);
    return false;
  }
  out.resize((size_t)sz);
  const size_t got = std::fread(out.data(), 1, (size_t)sz, fp);
  std::fclose(fp);
  return got == (size_t)sz;
}

// MAPPED_FILE (include/rgss_rom_bitmaps.h): the platform's in-place files.
static rgss_file_map_fn g_file_map = nullptr;

extern "C" void rgss_set_file_map(rgss_file_map_fn map) {
  g_file_map = map;
}

// The bytes of file `f`: in place when the platform maps it, else read into
// `buf`. False as slurp_file answers it.
static bool file_bytes(const char* f,
                       std::vector<uint8_t>& buf,
                       const uint8_t*& data,
                       size_t& size) {
  if (const void* p = g_file_map ? g_file_map(f, &size) : nullptr) {
    data = static_cast<const uint8_t*>(p);
    return size > 0;
  }
  if (!slurp_file(f, buf))
    return false;
  data = buf.data();
  size = buf.size();
  return true;
}

// Decode image bytes into `self` (a Bitmap). Shared by Bitmap#_init_file and
// #_init_memory: everything below is format work with no notion of where the
// bytes came from, which is what lets an entry pulled out of an encrypted
// RGSSAD archive go through the exact same decoders — stb, then the XYZ and
// tolerant-PNG fallbacks — as a loose file. `label` only names the source in
// the diagnostics. Answers false when nothing could decode it.
static bool bmp_decode_into(mrb_state* M,
                            mrb_value self,
                            const uint8_t* data,
                            size_t size,
                            const char* label,
                            bool trans) {
  int w, h, c;
  // Bytes in hand: from here on a failure is a decoder's, and worth reporting.
  g_bitmap_decoder_ran = true;
  if (indexed_bitmaps_enabled()) {
    IndexedImage ix;
    // XYZ goes straight to its own decoder below too: stb knows no format
    // that starts "XYZ1", so this is the decoder that would have run.
    if (load_png_indexed(data, size, trans, ix) ||
        load_xyz_indexed(data, size, label, trans, ix)) {
      Bitmap& bmp = DataType<Bitmap>::alloc_obj(M, self, ix.w, ix.h, kPixelI8,
                                                /* decoded = */ true);
      bmp.counter() -= bmp.bytes();
      bmp.buffer.swap(ix.idx);
      bmp.palette.swap(ix.pal);
      bmp.direct_format = ix.direct_bpp == 4 ? kPixelARGB8888 : kPixelRGB888;
      bmp.counter() += bmp.bytes();
      return true;
    }
  }
  stbi__png_transparent_palette = trans;
  // Every loader here hands back LVGL's B, G, R(, A) byte order (see
  // load_xyz_mem and load_png_tolerant_mem, which build it themselves). stb
  // decodes to R, G, B(, A), so its output is swapped below instead of relying
  // on the vendored palette-only BGR hack: that covered indexed PNGs (all an
  // RPG2000 project has) and left every truecolour PNG and every JPEG with red
  // and blue exchanged -- which is what an RPG Maker XP RTP is full of. Caught
  // by diffing against the genuine RGSS runtime.
  stbi__png_to_bgr_palette = false;
  // The channel count has to be decided before decoding, because the bitmap's
  // pixel format must follow what we *ask* stb for. It used to follow the
  // file's own channel count instead, so an RGBA image loaded without `trans`
  // allocated a 4-byte-per-pixel bitmap and filled it from 3-channel data --
  // reading past the decoded buffer and drawing garbage. An XP windowskin
  // (truecolour + alpha, loaded opaque) hit exactly that.
  int probe_w = 0, probe_h = 0, probe_c = 0;
  const bool has_alpha =
      stbi_info_from_memory(data, (int)size, &probe_w, &probe_h, &probe_c) &&
      probe_c == 4;
  const int req = (trans || has_alpha) ? 4 : 3;
  // Whether the pixels came from stb (R, G, B order, so they need the swap) or
  // from one of the fallbacks above, which already emit LVGL's order.
  bool from_stb = true;
  std::shared_ptr<uint8_t> img(
      stbi_load_from_memory(data, (int)size, &w, &h, &c, req), stbi_image_free);
  if (!img) {
    from_stb = false;
    img.reset(load_xyz_mem(data, size, label, &w, &h, &c, trans),
              stbi_image_free);
  }
  // stb_image rejects some valid-enough PNGs (e.g. RPG Maker windowskins whose
  // deflate stream references a zero pre-history, giving "bad dist"); retry
  // with the tolerant PNG decoder before giving up.
  if (!img)
    img.reset(load_png_tolerant_mem(data, size, label, &w, &h, &c, trans),
              stbi_image_free);
  if (!img)
    return false;
  // The fallbacks always produce 4 channels; stb produced exactly what was
  // requested.
  const int channels = from_stb ? req : 4;
  Bitmap& bmp = DataType<Bitmap>::alloc_obj(
      M, self, w, h, channels == 4 ? kPixelARGB8888 : kPixelRGB888,
      /* decoded = */ true);
  std::memcpy(bmp.buffer.data(), img.get(), bmp.buffer.size());
  if (from_stb) {
    uint8_t* p = bmp.buffer.data();
    for (size_t i = 0; i + 3 <= bmp.buffer.size(); i += (size_t)channels)
      std::swap(p[i], p[i + 2]);
  }
  return true;
}

// ROM_BITMAP: palette images that scripts/wio/game_rom.rb decoded ahead of
// time (rgss_indexed_decode.hxx's own decoders, run on the host) into a
// section of the game ROM, read in place instead of into the heap. Layout,
// little-endian u32s from the section's start: "RGSSRB01", entry count, 0,
// then per entry, sorted by path: path offset (NUL-terminated, relative to
// the game directory), pixel offset (one index per pixel, width as stride),
// width, height, then for a load without and with the colour key the palette
// offset (256 B, G, R, A entries) and the direct decode's bytes per pixel.
// RGSS_ROM_BITMAPS=0 (environment or build define) copies an entry into the
// heap instead, as the decoder would have.
//
// ROM_BITMAP_SOURCE (include/rgss_rom_bitmaps.h): only the directory is
// mapped, and a source maps each entry's blobs on demand, pinned while a
// bitmap points into them (Bitmap::rom_src).
#ifndef RGSS_ROM_BITMAPS
#define RGSS_ROM_BITMAPS 1
#endif
static bool rom_bitmaps_enabled() {
#if RGSS_ROM_BITMAPS
  static const bool on = [] {
    const char* e = std::getenv("RGSS_ROM_BITMAPS");
    return !(e && std::strcmp(e, "0") == 0);
  }();
  return on;
#else
  return false;
#endif
}

struct RomBitmapEntry {
  uint32_t path_off, px_off, w, h;
  uint32_t pal_off[2], bpp[2];
};

struct RomBitmaps {
  const uint8_t* base = nullptr;
  uint32_t count = 0;
  std::string root;
  const rgss_rom_bitmap_source* src = nullptr;
  const RomBitmapEntry* entries() const {
    return reinterpret_cast<const RomBitmapEntry*>(base + 16);
  }
  const char* path(const RomBitmapEntry& e) const {
    return reinterpret_cast<const char*>(base + e.path_off);
  }
};
static RomBitmaps g_rom_bitmaps;
// Set by the first rgss_set_rom_bitmaps, after which the environment's
// section (rom_bitmaps_from_env) no longer applies.
static bool g_rom_bitmaps_set = false;

static uint32_t rom_u32(const uint8_t* p) {
  return p[0] | (p[1] << 8) | (p[2] << 16) | (uint32_t(p[3]) << 24);
}

// Checks every offset once here, so a lookup can trust the section: the
// table and paths within the `mapped` bytes at `base`, the blobs within the
// section's `size`.
static bool rom_bitmaps_valid(const uint8_t* base, size_t mapped, size_t size) {
  if (mapped < 16 || mapped > size || std::memcmp(base, "RGSSRB01", 8) != 0)
    return false;
  const uint32_t n = rom_u32(base + 8);
  if (reinterpret_cast<uintptr_t>(base) % alignof(RomBitmapEntry) != 0 ||
      n > (mapped - 16) / sizeof(RomBitmapEntry))
    return false;
  const RomBitmapEntry* e = reinterpret_cast<const RomBitmapEntry*>(base + 16);
  const char* prev = nullptr;
  for (uint32_t i = 0; i < n; ++i) {
    if (e[i].path_off >= mapped ||
        !std::memchr(base + e[i].path_off, 0, mapped - e[i].path_off) ||
        e[i].w == 0 || e[i].h == 0 || e[i].w > (1u << 15) ||
        e[i].h > (1u << 15) || e[i].px_off > size ||
        uint64_t(e[i].w) * e[i].h > size - e[i].px_off)
      return false;
    for (int t = 0; t < 2; ++t)
      if (e[i].pal_off[t] > size || size - e[i].pal_off[t] < 256 * 4 ||
          (e[i].bpp[t] != 3 && e[i].bpp[t] != 4))
        return false;
    const char* p = reinterpret_cast<const char*>(base + e[i].path_off);
    if (prev && std::strcmp(prev, p) >= 0)
      return false;
    prev = p;
  }
  return true;
}

static bool rom_bitmaps_install(const void* section,
                                size_t mapped,
                                size_t size,
                                const char* root,
                                const rgss_rom_bitmap_source* src) {
  g_rom_bitmaps = RomBitmaps{};
  g_rom_bitmaps_set = true;
  if (!section)
    return true;
  const uint8_t* base = static_cast<const uint8_t*>(section);
  if (!rom_bitmaps_valid(base, mapped, size)) {
    std::fprintf(stderr,
                 "[RGSS] ROM bitmaps: a malformed %lu-byte section; decoding "
                 "every image instead\n",
                 static_cast<unsigned long>(size));
    return false;
  }
  g_rom_bitmaps.base = base;
  g_rom_bitmaps.count = rom_u32(base + 8);
  g_rom_bitmaps.root = root ? root : "";
  g_rom_bitmaps.src = src;
  return true;
}

// See include/rgss_rom_bitmaps.h.
extern "C" bool rgss_set_rom_bitmaps(const void* section,
                                     size_t size,
                                     const char* root) {
  return rom_bitmaps_install(section, size, size, root, nullptr);
}

extern "C" bool rgss_set_rom_bitmap_source(const void* directory,
                                           size_t dir_size,
                                           size_t section_size,
                                           const char* root,
                                           const rgss_rom_bitmap_source* src) {
  return rom_bitmaps_install(directory, dir_size, section_size, root, src);
}

#if !defined(WIO_TERMINAL)
// RGSS_ROM_BITMAPS_IMAGE names a section file (game_rom.rb --bitmaps-out)
// and RGSS_ROM_BITMAPS_ROOT the game directory, so a host run takes the ROM
// path too.
static std::vector<uint8_t> g_rom_bitmaps_host;
static void rom_bitmaps_from_env() {
  if (g_rom_bitmaps_set)
    return;
  g_rom_bitmaps_set = true;
  const char* img = std::getenv("RGSS_ROM_BITMAPS_IMAGE");
  if (!img || !*img)
    return;
  if (!slurp_file(img, g_rom_bitmaps_host)) {
    std::fprintf(stderr, "[RGSS] ROM bitmaps: cannot read %s\n", img);
    return;
  }
  const char* root = std::getenv("RGSS_ROM_BITMAPS_ROOT");
  rgss_set_rom_bitmaps(g_rom_bitmaps_host.data(), g_rom_bitmaps_host.size(),
                       root ? root : "");
}
#endif

// The entry for the file `f`, or nullptr.
static const RomBitmapEntry* rom_bitmap_find(const char* f) {
#if !defined(WIO_TERMINAL)
  rom_bitmaps_from_env();
#endif
  const RomBitmaps& r = g_rom_bitmaps;
  if (!r.base)
    return nullptr;
  const size_t n = r.root.size();
  if (n) {
    if (std::strncmp(f, r.root.data(), n) != 0 || f[n] != '/')
      return nullptr;
    f += n + 1;
  }
  const RomBitmapEntry* e = r.entries();
  size_t lo = 0, hi = r.count;
  while (lo < hi) {
    const size_t mid = (lo + hi) / 2;
    const int c = std::strcmp(r.path(e[mid]), f);
    if (c == 0)
      return &e[mid];
    if (c < 0)
      lo = mid + 1;
    else
      hi = mid;
  }
  return nullptr;
}

// Loads `f` from the ROM bitmaps when it is there. The packer leaves an
// entry's file out of the image, so this answers for it even with
// RGSS_ROM_BITMAPS=0 or RGSS_INDEXED_BITMAPS=0.
static bool bmp_init_rom(mrb_state* M,
                         mrb_value self,
                         const char* f,
                         bool trans) {
  const RomBitmapEntry* e = rom_bitmap_find(f);
  if (!e)
    return false;
  const uint8_t* px;
  const uint8_t* pal;
  // Holds the source's pin until the bitmap takes it, so a raise in between
  // (alloc_obj's) does not leave the entry pinned for good.
  struct Pin {
    const rgss_rom_bitmap_source* src;
    uint32_t index;
    ~Pin() {
      if (src)
        src->release(src->ctx, index);
    }
  } pin{nullptr, static_cast<uint32_t>(e - g_rom_bitmaps.entries())};
  if (const rgss_rom_bitmap_source* src = g_rom_bitmaps.src) {
    rgss_rom_bitmap_view v;
    rgss_rom_fetch_result got = src->fetch(src->ctx, pin.index, &v);
    if (got == RGSS_ROM_FETCH_FULL) {
      // The pins of bitmaps nothing holds any more go with their collection.
      mrb_full_gc(M);
      got = src->fetch(src->ctx, pin.index, &v);
    }
    if (got != RGSS_ROM_FETCH_OK)
      return false;
    pin.src = src;
    px = v.px;
    pal = v.pal[trans];
  } else {
    px = g_rom_bitmaps.base + e->px_off;
    pal = g_rom_bitmaps.base + e->pal_off[trans];
  }
  // Built empty: an I8 buffer of the full size would be the very copy this
  // avoids.
  Bitmap& bmp = DataType<Bitmap>::alloc_obj(M, self, 0, 0, kPixelI8,
                                            /* decoded = */ true);
  bmp.width = static_cast<int32_t>(e->w);
  bmp.height = static_cast<int32_t>(e->h);
  bmp.direct_format = e->bpp[trans] == 4 ? kPixelARGB8888 : kPixelRGB888;
  if (rom_bitmaps_enabled()) {
    bmp.rom_px = px;
    bmp.rom_pal = pal;
    bmp.rom_src = pin.src;
    bmp.rom_index = pin.index;
    pin.src = nullptr;
  } else {
    bmp.counter() -= bmp.bytes();
    bmp.buffer.assign(px, px + size_t(e->w) * e->h);
    bmp.palette.assign(pal, pal + 256 * 4);
    bmp.counter() += bmp.bytes();
  }
  if (!indexed_bitmaps_enabled())
    promote_to_direct(bmp);
  return true;
}

#if !defined(WIO_TERMINAL)
// Ruby: Bitmap._pixel_bytes -> the heap bytes every live bitmap's pixels and
// palettes take (the tests' view of LAZY_PIXELS).
mrb_value bmp_s_pixel_bytes(mrb_state* M, V self) {
  (void)self;
  return mrb_int_value(
      M, static_cast<mrb_int>(g_bitmap_bytes_decoded + g_bitmap_bytes_blank));
}

// Ruby: Bitmap._rom_bitmaps(section or nil, root) -> whether it was taken.
// The tests' way in to the ROM path. Each section is copied and kept for good:
// bitmaps loaded from an earlier one still point into it.
static std::vector<std::unique_ptr<std::vector<uint8_t>>> g_rom_bitmaps_ruby;
mrb_value bmp_s_rom_bitmaps(mrb_state* M, V self) {
  (void)self;
  mrb_value sec;
  const char* root;
  mrb_get_args(M, "oz", &sec, &root);
  if (mrb_nil_p(sec))
    return mrb_bool_value(rgss_set_rom_bitmaps(nullptr, 0, nullptr));
  sec = mrb_ensure_string_type(M, sec);
  const uint8_t* p = reinterpret_cast<const uint8_t*>(RSTRING_PTR(sec));
  g_rom_bitmaps_ruby.push_back(
      std::make_unique<std::vector<uint8_t>>(p, p + RSTRING_LEN(sec)));
  const std::vector<uint8_t>& v = *g_rom_bitmaps_ruby.back();
  return mrb_bool_value(rgss_set_rom_bitmaps(v.data(), v.size(), root));
}

// The tests' ROM_BITMAP_SOURCE: maps entries out of a whole section in memory,
// counting pins, and answers FULL once `limit` entries are pinned (FAILED for
// every entry when `limit` is 0).
struct TestRomSource {
  rgss_rom_bitmap_source api;
  std::vector<uint8_t> section;
  std::vector<uint32_t> pins;
  uint32_t limit;
};
static std::vector<std::unique_ptr<TestRomSource>> g_rom_sources_ruby;

static rgss_rom_fetch_result test_rom_fetch(void* ctx,
                                            uint32_t index,
                                            rgss_rom_bitmap_view* out) {
  TestRomSource& t = *static_cast<TestRomSource*>(ctx);
  if (t.limit == 0 || index >= t.pins.size())
    return RGSS_ROM_FETCH_FAILED;
  if (!t.pins[index] && std::count_if(t.pins.begin(), t.pins.end(),
                                      [](uint32_t n) { return n != 0; }) >=
                            static_cast<long>(t.limit))
    return RGSS_ROM_FETCH_FULL;
  const RomBitmapEntry& e =
      reinterpret_cast<const RomBitmapEntry*>(t.section.data() + 16)[index];
  out->px = t.section.data() + e.px_off;
  out->pal[0] = t.section.data() + e.pal_off[0];
  out->pal[1] = t.section.data() + e.pal_off[1];
  ++t.pins[index];
  return RGSS_ROM_FETCH_OK;
}

static void test_rom_release(void* ctx, uint32_t index) {
  TestRomSource& t = *static_cast<TestRomSource*>(ctx);
  if (index >= t.pins.size() || t.pins[index] == 0) {
    std::fprintf(stderr, "[RGSS] ROM bitmaps: entry %u released unpinned\n",
                 static_cast<unsigned>(index));
    std::abort();
  }
  --t.pins[index];
}

// Ruby: Bitmap._rom_bitmap_source(section, root, limit) -> whether it was
// taken. The directory is the section's bytes before its first blob.
mrb_value bmp_s_rom_bitmap_source(mrb_state* M, V self) {
  (void)self;
  mrb_value sec;
  const char* root;
  mrb_int limit;
  mrb_get_args(M, "Szi", &sec, &root, &limit);
  auto t = std::make_unique<TestRomSource>();
  const uint8_t* p = reinterpret_cast<const uint8_t*>(RSTRING_PTR(sec));
  t->section.assign(p, p + RSTRING_LEN(sec));
  t->limit = static_cast<uint32_t>(limit);
  size_t dir = t->section.size();
  const uint32_t n = t->section.size() >= 16 ? rom_u32(p + 8) : 0;
  if (n <= (t->section.size() - std::min<size_t>(t->section.size(), 16)) /
               sizeof(RomBitmapEntry)) {
    const RomBitmapEntry* e = reinterpret_cast<const RomBitmapEntry*>(p + 16);
    for (uint32_t i = 0; i < n; ++i)
      dir = std::min<size_t>(
          dir, std::min({e[i].px_off, e[i].pal_off[0], e[i].pal_off[1]}));
  }
  t->pins.assign(n, 0);
  t->api = {test_rom_fetch, test_rom_release, t.get()};
  const bool ok = rgss_set_rom_bitmap_source(t->section.data(), dir,
                                             t->section.size(), root, &t->api);
  g_rom_sources_ruby.push_back(std::move(t));
  return mrb_bool_value(ok);
}

// Ruby: Bitmap._rom_bitmap_pins -> the pins every test source holds. A test
// hook: kept out of the direct-call table (binding_split.rb) by checking its
// arguments after the first statement, as the other hooks here do.
mrb_value bmp_s_rom_bitmap_pins(mrb_state* M, V self) {
  (void)self;
  mrb_get_args(M, "");
  mrb_int n = 0;
  for (const auto& t : g_rom_sources_ruby)
    for (uint32_t c : t->pins)
      n += c;
  return mrb_int_value(M, n);
}
#endif

mrb_value bmp_init_file(mrb_state* M, mrb_value self) {
  const char* f;
  mrb_bool trans = false;
  mrb_get_args(M, "z|b", &f, &trans);
  if (bmp_init_rom(M, self, f, trans))
    return self;
  std::vector<uint8_t> data;
  const uint8_t* bytes = nullptr;
  size_t size = 0;
  if (file_bytes(f, data, bytes, size) &&
      bmp_decode_into(M, self, bytes, size, f, trans))
    return self;
#ifndef WIO_TERMINAL
  // Some archives store filenames in NFD form while the game data refers to
  // them in NFC (or vice versa); retry with the decomposed form before giving
  // up so accented paths still resolve. Skipped on wio: see to_nfd's own
  // comment above for why this ~94 KB uni-algo table set isn't worth it on a
  // 496 KB-flash target -- the exact same tradeoff applies here.
  const std::string nfd_f = una::norm::to_nfd_utf8(f);
  if (nfd_f != f && slurp_file(nfd_f.c_str(), data) &&
      bmp_decode_into(M, self, data.data(), data.size(), nfd_f.c_str(), trans))
    return self;
#endif
  return mrb_nil_value();
}

// Ruby: Bitmap#_init_memory(bytes, transparent = false) -> self or nil.
//
// The same decode as #_init_file over bytes already in hand. RGSS's Cache
// asks for every asset by name (`Bitmap.new("Graphics/Titles/...")`), and a
// released game packs those names into its encrypted Game.rgssad / .rgss2a /
// .rgss3a with nothing loose on disk — so the Ruby loader falls back to the
// archive and hands the decrypted bytes here.
mrb_value bmp_init_memory(mrb_state* M, mrb_value self) {
  const char* data;
  mrb_int size;
  mrb_bool trans = false;
  mrb_get_args(M, "s|b", &data, &size, &trans);
  if (size <= 0)
    return mrb_nil_value();
  if (!bmp_decode_into(M, self, reinterpret_cast<const uint8_t*>(data),
                       (size_t)size, "<archive entry>", trans))
    return mrb_nil_value();
  return self;
}

Bitmap& bmp_self(mrb_state* M, V self) {
  return DataType<Bitmap>::get(M, self);
}

// bmp_self without materializing a deferred bitmap: the recording draws and
// the size readers.
Bitmap& bmp_raw(mrb_state* M, V self) {
  return DataType<Bitmap>::raw(M, self);
}

// Bitmap#dispose nulls the data pointer but leaves the mruby wrapper object
// alive and non-nil (see obj_dispose), so mrb_get_args's "d" specifier -- which
// only raises on a type mismatch, not a null payload -- happily hands back a
// NULL RData-data-field value for an already-disposed source. Blt-style
// methods used to dereference that pointer directly and segfault the whole
// process; this turns it into a catchable RGSSError instead, matching real
// RGSS.
//
// `p` is whatever mrb_get_args' own "d" format specifier hands back --
// literally the RData's own `data` field (mrb_data_get_ptr's return value),
// which for a DataType<Bitmap>-backed object is now the shared_ptr<Bitmap>
// *box* (see DataType<T>'s own comment), not a Bitmap* directly. Every
// bmp_blt/bmp_blt_quads/bmp_copy_blt/bmp_stretch_blt call site below passes
// this straight through from its own "...d...", &DataType<Bitmap>::data_type
// mrb_get_args call -- fixed here in one place rather than at each of those
// four, so a future blt-style method reusing this same "d"-spec pattern
// inherits the right unwrapping for free.
Bitmap& bmp_require(mrb_state* M, void* p) {
  if (!p) {
    RClass* mod = mrb_module_get_id(M, MRB_SYM(RGSS));
    mrb_raise(M, mrb_class_get_under_id(M, mod, MRB_SYM(RGSSError)),
              "disposed Bitmap");
  }
  Bitmap& b = **reinterpret_cast<std::shared_ptr<Bitmap>*>(p);
  settle_for_access(b);
  return b;
}

// The shared owner behind a "d"-spec argument, for a draw recorded into a
// deferred bitmap (which keeps its sources alive).
const std::shared_ptr<Bitmap>& bmp_require_shared(mrb_state* M, void* p) {
  if (!p) {
    RClass* mod = mrb_module_get_id(M, MRB_SYM(RGSS));
    mrb_raise(M, mrb_class_get_under_id(M, mod, MRB_SYM(RGSSError)),
              "disposed Bitmap");
  }
  const std::shared_ptr<Bitmap>& s =
      *reinterpret_cast<std::shared_ptr<Bitmap>*>(p);
  ensure_pixels(*s);
  return s;
}

// Write an RGBA color into the bitmap at (x, y). LVGL stores ARGB8888 as
// B, G, R, A bytes (and RGB888 as B, G, R), matching how images are loaded.
void bmp_put(Bitmap& b,
             mrb_int x,
             mrb_int y,
             double r,
             double g,
             double bl,
             double a) {
  if (x < 0 || y < 0 || x >= b.width || y >= b.height)
    return;
  promote_to_direct(b);
  const unsigned bpp = pixel_size(b.format);
  uint8_t* p = b.buffer.data() + ((size_t)y * b.width + x) * bpp;
  p[0] = (uint8_t)bl;
  p[1] = (uint8_t)g;
  p[2] = (uint8_t)r;
  if (bpp >= 4)
    p[3] = (uint8_t)a;
}

void bmp_read(const Bitmap& b,
              mrb_int x,
              mrb_int y,
              int& r,
              int& g,
              int& bl,
              int& a) {
  if (b.indexed()) {
    const uint8_t* p = b.pal() + b.px()[(size_t)y * b.width + x] * 4u;
    bl = p[0];
    g = p[1];
    r = p[2];
    a = p[3];
    return;
  }
  const unsigned bpp = pixel_size(b.format);
  const uint8_t* p = b.buffer.data() + ((size_t)y * b.width + x) * bpp;
  bl = p[0];
  g = p[1];
  r = p[2];
  a = bpp >= 4 ? p[3] : 255;
}

// Source-over composite of one pixel in *straight* (non-premultiplied) alpha.
//
// The obvious `src*a + dst*(255-a)` is only right when the destination is
// opaque. Onto a transparent pixel -- which is transparent *black* -- it drags
// the colour toward black while recording alpha `a`, so the composite that
// later draws the bitmap over the screen attenuates the same colour a second
// time. A window background blitted at RGSS's `back_opacity` 160 came out
// showing 8% of its skin instead of 63% (measured against the genuine RGSS
// runtime, which blends at exactly back_opacity/255).
//
// Straight alpha keeps the colour and lets the alpha carry the coverage:
//   out_a   = sa + da*(1 - sa)
//   out_rgb = (src*sa + dst*da*(1 - sa)) / out_a
// which reduces to the old formula when da is 255, so blits onto an opaque
// bitmap are unchanged.
void blend_over(Bitmap& dst,
                mrb_int x,
                mrb_int y,
                int r,
                int g,
                int b,
                int sa,
                int dr,
                int dg,
                int db,
                int da) {
  const int dw = da * (255 - sa) / 255;
  const int out_a = sa + dw;
  if (out_a <= 0)
    return;
  bmp_put(dst, x, y, (r * sa + dr * dw) / out_a, (g * sa + dg * dw) / out_a,
          (b * sa + db * dw) / out_a, out_a);
}

mrb_value bmp_width(mrb_state* M, V self) {
  return mrb_fixnum_value(bmp_raw(M, self).width);
}

mrb_value bmp_height(mrb_state* M, V self) {
  return mrb_fixnum_value(bmp_raw(M, self).height);
}

mrb_value bmp_rect(mrb_state* M, V self) {
  Bitmap& b = bmp_raw(M, self);
  const V args[] = {mrb_fixnum_value(0), mrb_fixnum_value(0),
                    mrb_fixnum_value(b.width), mrb_fixnum_value(b.height)};
  return mrb_obj_new(M,
                     mrb_class_get_under_id(
                         M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Rect)),
                     4, args);
}

void deferred_clear(Bitmap& b);
bool deferred_begin(Bitmap& b);

mrb_value bmp_clear(mrb_state* M, V self) {
  Bitmap& b = bmp_raw(M, self);
  if (b.deferred || deferred_begin(b)) {
    deferred_clear(b);
    b.dirty = true;
    return self;
  }
  if (!b.lazy) {
    promote_to_direct(b, /* keep = */ false);
    std::fill(b.buffer.begin(), b.buffer.end(), 0);
  }
  b.dirty = true;
  return self;
}

void fill_pixels(Bitmap& b,
                 mrb_int x,
                 mrb_int y,
                 mrb_int w,
                 mrb_int h,
                 const Color& c);

mrb_value bmp_fill_rect(mrb_state* M, V self) {
  Bitmap& b = bmp_raw(M, self);
  mrb_int x, y, w, h;
  V col;
  if (mrb_get_argc(M) <= 2) {
    V r;
    mrb_get_args(M, "oo", &r, &col);
    Rect& rc = DataType<Rect>::get(M, r);
    x = rc.x;
    y = rc.y;
    w = rc.width;
    h = rc.height;
  } else {
    mrb_get_args(M, "iiiio", &x, &y, &w, &h, &col);
    return rgss::bitmap_fill_rect_direct(
        M, self, mrb_int_value(M, x), mrb_int_value(M, y), mrb_int_value(M, w),
        mrb_int_value(M, h), col);
  }
  fill_pixels(b, x, y, w, h, DataType<Color>::get(M, col));
  b.dirty = true;
  return self;
}

int clamp_channel(int v) {
  return v < 0 ? 0 : (v > 255 ? 255 : v);
}

// RGSS Bitmap#tone_blt(src, tone): copy `src` into this bitmap, same size,
// applying an RGSS Tone.
//
// A tone is *not* a colour drawn on top -- it rescales what is already there,
// which is why it cannot be done the way the screen fade and flash are (a solid
// sprite composited at some opacity). Hence a real pixel pass.
//
// RGSS order, which RPG2000's Tint Screen reduces to: desaturate toward
// luminance by `gray` (0..255), then add the per-channel offsets (-255..255).
// Luminance uses the usual 299/587/114 weights. Alpha is copied untouched: a
// tone tints what is visible, it does not make anything more or less so.
//
// It writes into a separate destination rather than transforming in place
// because the caller redraws its layers only when they change; toning in place
// would re-tone an already-toned layer every frame and march it to black.
mrb_value bmp_tone_blt(mrb_state* M, V self) {
  Bitmap& dst = bmp_self(M, self);
  V src_v, tone_v;
  mrb_get_args(M, "oo", &src_v, &tone_v);
  Bitmap& src = DataType<Bitmap>::get(M, src_v);
  Tone& t = DataType<Tone>::get(M, tone_v);

  if (src.width != dst.width || src.height != dst.height) {
    RClass* mod = mrb_module_get_id(M, MRB_SYM(RGSS));
    RClass* err = mrb_class_get_under_id(M, mod, MRB_SYM(RGSSError));
    mrb_raisef(M, err, "tone_blt: size mismatch (self %dx%d, src %dx%d)",
               dst.width, dst.height, src.width, src.height);
  }

  const int tr = (int)t.red;
  const int tg = (int)t.green;
  const int tb = (int)t.blue;
  const int gray = (int)t.gray;
  for (int32_t y = 0; y < src.height; ++y) {
    for (int32_t x = 0; x < src.width; ++x) {
      int r, g, b, a;
      bmp_read(src, x, y, r, g, b, a);
      if (gray > 0) {
        const int lum = (r * 299 + g * 587 + b * 114) / 1000;
        r += (lum - r) * gray / 255;
        g += (lum - g) * gray / 255;
        b += (lum - b) * gray / 255;
      }
      r = clamp_channel(r + tr);
      g = clamp_channel(g + tg);
      b = clamp_channel(b + tb);
      bmp_put(dst, x, y, r, g, b, a);
    }
  }
  dst.dirty = true;
  return self;
}

// RGSS Bitmap#gradient_fill_rect(rect, color1, color2, vertical=false) or
// (x, y, width, height, color1, color2, vertical=false): fill the rect with a
// linear gradient from color1 to color2, left-to-right (or top-to-bottom when
// vertical). Like fill_rect, it overwrites the pixels (colour + alpha).
#if !defined(WIO_TERMINAL)  // dead weight on wio: no Ruby path reaches it
mrb_value bmp_gradient_fill_rect(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  mrb_int x, y, w, h;
  V col1, col2;
  mrb_bool vertical = false;
  if (mrb_get_argc(M) <= 4) {
    V r;
    mrb_get_args(M, "ooo|b", &r, &col1, &col2, &vertical);
    Rect& rc = DataType<Rect>::get(M, r);
    x = rc.x;
    y = rc.y;
    w = rc.width;
    h = rc.height;
  } else {
    mrb_get_args(M, "iiiioo|b", &x, &y, &w, &h, &col1, &col2, &vertical);
  }
  Color& c1 = DataType<Color>::get(M, col1);
  Color& c2 = DataType<Color>::get(M, col2);
  const mrb_int span = vertical ? h : w;
  for (mrb_int j = y; j < y + h; ++j) {
    for (mrb_int i = x; i < x + w; ++i) {
      const mrb_int pos = vertical ? (j - y) : (i - x);
      const double t = span > 1 ? static_cast<double>(pos) / (span - 1) : 0.0;
      bmp_put(b, i, j, c1.red + (c2.red - c1.red) * t,
              c1.green + (c2.green - c1.green) * t,
              c1.blue + (c2.blue - c1.blue) * t,
              c1.alpha + (c2.alpha - c1.alpha) * t);
    }
  }
  b.dirty = true;
  return self;
}
#endif  // !defined(WIO_TERMINAL)

// RGSS Bitmap#hue_change(hue): rotate every pixel's hue by `hue` degrees,
// preserving saturation, value and alpha (an RGB -> HSV -> RGB pass, matching
// RMXP's hue rotation). A hue of 0 (mod 360) is a no-op.
// RGSS Bitmap#blur: soften the whole bitmap in place.
//
// A 3x3 box blur, run over a copy so every output pixel reads the *original*
// neighbourhood -- blurring in place would feed already-blurred pixels back in
// and smear along the scan order rather than evenly. Edge pixels average only
// the neighbours that exist, so the border is not darkened toward transparent.
//
// The channels are averaged premultiplied by alpha, which is what stops a
// transparent neighbour dragging colour out of an opaque pixel: a transparent
// pixel has no colour to contribute, only weight. RGSS's own blur is a
// fixed, mild one with no parameters, so there is nothing here to tune.
#if !defined(WIO_TERMINAL)  // dead weight on wio: no Ruby path reaches it
mrb_value bmp_blur(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  if (b.width < 1 || b.height < 1)
    return self;
  promote_to_direct(b);
  const std::vector<uint8_t> src = b.buffer;
  // Read through the untouched copy, not the bitmap being written.
  auto read_src = [&](int32_t x, int32_t y, int& r, int& g, int& bl, int& a) {
    const unsigned bpp = pixel_size(b.format);
    const uint8_t* p = src.data() + ((size_t)y * b.width + x) * bpp;
    bl = p[0];
    g = p[1];
    r = p[2];
    a = bpp >= 4 ? p[3] : 255;
  };
  for (int32_t y = 0; y < b.height; ++y) {
    for (int32_t x = 0; x < b.width; ++x) {
      int rs = 0, gs = 0, bs = 0, as = 0, n = 0;
      for (int32_t dy = -1; dy <= 1; ++dy) {
        for (int32_t dx = -1; dx <= 1; ++dx) {
          const int32_t sx = x + dx, sy = y + dy;
          if (sx < 0 || sy < 0 || sx >= b.width || sy >= b.height)
            continue;
          int r, g, bl, a;
          read_src(sx, sy, r, g, bl, a);
          rs += r * a / 255;
          gs += g * a / 255;
          bs += bl * a / 255;
          as += a;
          ++n;
        }
      }
      if (n == 0)
        continue;
      const int a = as / n;
      // Undo the premultiply. A fully transparent result has no colour to
      // recover, so leave it black rather than dividing by zero.
      const int r = a > 0 ? std::min(255, rs * 255 / n / a) : 0;
      const int g = a > 0 ? std::min(255, gs * 255 / n / a) : 0;
      const int bl = a > 0 ? std::min(255, bs * 255 / n / a) : 0;
      bmp_put(b, x, y, r, g, bl, a);
    }
  }
  b.dirty = true;
  return self;
}
#endif  // !defined(WIO_TERMINAL)

// RGSS Bitmap#radial_blur(angle, division): a rotational blur about the centre.
//
// `division` copies of the image, spread evenly over `angle` degrees and
// centred on the original (so the result is symmetric rather than smeared to
// one side), averaged together. Sampling is nearest-neighbour; samples that
// rotate off the bitmap contribute nothing, which keeps the corners from
// pulling in transparent pixels and going dark. As in #blur the average is
// taken premultiplied.
//
// division < 2 or angle == 0 is the identity, matching "no rotation to spread
// over" rather than dividing by zero.
#if !defined(WIO_TERMINAL)  // dead weight on wio: no Ruby path reaches it
mrb_value bmp_radial_blur(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  mrb_int angle, division;
  mrb_get_args(M, "ii", &angle, &division);
  if (division < 2 || angle == 0 || b.width < 1 || b.height < 1)
    return self;
  promote_to_direct(b);
  const std::vector<uint8_t> src = b.buffer;
  const unsigned bpp = pixel_size(b.format);
  auto read_src = [&](int32_t x, int32_t y, int& r, int& g, int& bl, int& a) {
    const uint8_t* p = src.data() + ((size_t)y * b.width + x) * bpp;
    bl = p[0];
    g = p[1];
    r = p[2];
    a = bpp >= 4 ? p[3] : 255;
  };
  const double cx = (b.width - 1) / 2.0;
  const double cy = (b.height - 1) / 2.0;
  const double span = angle * 3.14159265358979323846 / 180.0;
  for (int32_t y = 0; y < b.height; ++y) {
    for (int32_t x = 0; x < b.width; ++x) {
      int rs = 0, gs = 0, bs = 0, as = 0, n = 0;
      for (mrb_int k = 0; k < division; ++k) {
        // -span/2 .. +span/2, so the unrotated image sits in the middle.
        const double t = (double)k / (double)(division - 1) - 0.5;
        const double th = span * t;
        const double s = std::sin(th), c = std::cos(th);
        const double dx = x - cx, dy = y - cy;
        const int32_t sx = (int32_t)::lround(cx + dx * c - dy * s);
        const int32_t sy = (int32_t)::lround(cy + dx * s + dy * c);
        if (sx < 0 || sy < 0 || sx >= b.width || sy >= b.height)
          continue;
        int r, g, bl, a;
        read_src(sx, sy, r, g, bl, a);
        rs += r * a / 255;
        gs += g * a / 255;
        bs += bl * a / 255;
        as += a;
        ++n;
      }
      if (n == 0)
        continue;
      const int a = as / n;
      const int r = a > 0 ? std::min(255, rs * 255 / n / a) : 0;
      const int g = a > 0 ? std::min(255, gs * 255 / n / a) : 0;
      const int bl = a > 0 ? std::min(255, bs * 255 / n / a) : 0;
      bmp_put(b, x, y, r, g, bl, a);
    }
  }
  b.dirty = true;
  return self;
}
#endif  // !defined(WIO_TERMINAL)

#if !defined(WIO_TERMINAL)  // dead weight on wio: no Ruby path reaches it
// One pixel's hue rotated by `hue` degrees, as the doubles bmp_put truncates.
static void hue_rotate_px(int r, int g, int bl, mrb_int hue, double out[3]) {
  const double rf = r / 255.0, gf = g / 255.0, bf = bl / 255.0;
  const double mx = std::max(rf, std::max(gf, bf));
  const double mn = std::min(rf, std::min(gf, bf));
  const double delta = mx - mn;
  double h = 0.0;
  if (delta > 0.0) {
    if (mx == rf)
      h = 60.0 * std::fmod((gf - bf) / delta, 6.0);
    else if (mx == gf)
      h = 60.0 * ((bf - rf) / delta + 2.0);
    else
      h = 60.0 * ((rf - gf) / delta + 4.0);
    if (h < 0.0)
      h += 360.0;
  }
  const double s = mx == 0.0 ? 0.0 : delta / mx;
  const double v = mx;
  h = std::fmod(h + hue, 360.0);
  // HSV -> RGB.
  const double c = v * s;
  const double xx = c * (1.0 - std::fabs(std::fmod(h / 60.0, 2.0) - 1.0));
  const double m = v - c;
  double nr, ng, nb;
  if (h < 60.0) {
    nr = c;
    ng = xx;
    nb = 0.0;
  } else if (h < 120.0) {
    nr = xx;
    ng = c;
    nb = 0.0;
  } else if (h < 180.0) {
    nr = 0.0;
    ng = c;
    nb = xx;
  } else if (h < 240.0) {
    nr = 0.0;
    ng = xx;
    nb = c;
  } else if (h < 300.0) {
    nr = xx;
    ng = 0.0;
    nb = c;
  } else {
    nr = c;
    ng = 0.0;
    nb = xx;
  }
  out[0] = (nr + m) * 255.0;
  out[1] = (ng + m) * 255.0;
  out[2] = (nb + m) * 255.0;
}

mrb_value bmp_hue_change(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  mrb_int hue;
  mrb_get_args(M, "i", &hue);
  hue = ((hue % 360) + 360) % 360;
  if (hue == 0)
    return self;
  double o[3];
  if (b.indexed()) {
    // Each pixel's result depends on its colour alone, so rotating the
    // palette is the per-pixel pass exactly; alpha is untouched either way.
    own_palette(b);
    for (size_t k = 0; k < b.palette.size(); k += 4) {
      uint8_t* e = &b.palette[k];
      hue_rotate_px(e[2], e[1], e[0], hue, o);
      e[0] = (uint8_t)o[2];
      e[1] = (uint8_t)o[1];
      e[2] = (uint8_t)o[0];
    }
    b.dirty = true;
    return self;
  }
  for (int32_t y = 0; y < b.height; ++y) {
    for (int32_t x = 0; x < b.width; ++x) {
      int r, g, bl, a;
      bmp_read(b, x, y, r, g, bl, a);
      hue_rotate_px(r, g, bl, hue, o);
      bmp_put(b, x, y, o[0], o[1], o[2], a);
    }
  }
  b.dirty = true;
  return self;
}
#endif  // !defined(WIO_TERMINAL)

mrb_value bmp_get_pixel(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  mrb_int x, y;
  mrb_get_args(M, "ii", &x, &y);
  int r = 0, g = 0, bl = 0, a = 0;
  if (x >= 0 && y >= 0 && x < b.width && y < b.height)
    bmp_read(b, x, y, r, g, bl, a);
  const V args[] = {rgss::num_value(M, r), rgss::num_value(M, g),
                    rgss::num_value(M, bl), rgss::num_value(M, a)};
  return mrb_obj_new(
      M,
      mrb_class_get_under_id(M, mrb_module_get_id(M, MRB_SYM(RGSS)),
                             MRB_SYM(Color)),
      4, args);
}

#if !defined(WIO_TERMINAL)  // dead weight on wio: no Ruby path reaches it
mrb_value bmp_set_pixel(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  mrb_int x, y;
  V col;
  mrb_get_args(M, "iio", &x, &y, &col);
  Color& c = DataType<Color>::get(M, col);
  bmp_put(b, x, y, c.red, c.green, c.blue, c.alpha);
  b.dirty = true;
  return self;
}
#endif  // !defined(WIO_TERMINAL)

// Composite one source row onto one destination row: `w` pixels from source
// row `sy` starting at column `sx`, written from destination column `x` on row
// `y`. The per-pixel body of the old blt_pixels loop, kept verbatim so the
// fast path below cannot drift from it. Callers pass an already-clipped rect,
// so no bounds checks -- every pixel lands inside both bitmaps.
static void blt_row_pixels(Bitmap& dst,
                           const Bitmap& sb,
                           mrb_int x,
                           mrb_int y,
                           mrb_int sx,
                           mrb_int sy,
                           mrb_int w,
                           int opacity) {
  for (mrb_int col = 0; col < w; ++col) {
    int r, g, bl, a;
    bmp_read(sb, sx + col, sy, r, g, bl, a);
    const int alpha = a * opacity / 255;
    if (alpha <= 0)
      continue;
    if (alpha >= 255) {
      bmp_put(dst, x + col, y, r, g, bl, 255);
      continue;
    }
    int dr, dg, db, da;
    bmp_read(dst, x + col, y, dr, dg, db, da);
    blend_over(dst, x + col, y, r, g, bl, alpha, dr, dg, db, da);
  }
}

// blt_row_pixels at full opacity from an indexed source, with the palette
// lookup inlined: the chipset/charset blits of the map renderer's hot path.
static void blt_row_indexed(Bitmap& dst,
                            const Bitmap& sb,
                            mrb_int x,
                            mrb_int y,
                            mrb_int sx,
                            mrb_int sy,
                            mrb_int w) {
  const unsigned bpp = pixel_size(dst.format);
  const uint8_t* s = sb.px() + (size_t)sy * sb.width + sx;
  uint8_t* d = dst.buffer.data() + ((size_t)y * dst.width + x) * bpp;
  const uint8_t* pal = sb.pal();
  for (mrb_int col = 0; col < w; ++col, d += bpp) {
    const uint8_t* p = pal + s[col] * 4u;
    const int a = p[3];
    if (a == 255) {
      d[0] = p[0];
      d[1] = p[1];
      d[2] = p[2];
      if (bpp >= 4)
        d[3] = 255;
    } else if (a > 0) {
      int dr, dg, db, da;
      bmp_read(dst, x + col, y, dr, dg, db, da);
      blend_over(dst, x + col, y, p[2], p[1], p[0], a, dr, dg, db, da);
    }
  }
}

// Clip a blit of sb's (sx, sy, w, h) at (x, y) against both bitmaps, carrying
// the destination along with the source.
static void clip_blit(const Bitmap& dst,
                      const Bitmap& sb,
                      mrb_int& x,
                      mrb_int& y,
                      mrb_int& sx,
                      mrb_int& sy,
                      mrb_int& w,
                      mrb_int& h) {
  if (sx < 0) {
    w += sx;
    x -= sx;
    sx = 0;
  }
  if (sy < 0) {
    h += sy;
    y -= sy;
    sy = 0;
  }
  if (x < 0) {
    w += x;
    sx -= x;
    x = 0;
  }
  if (y < 0) {
    h += y;
    sy -= y;
    y = 0;
  }
  if (sx + w > sb.width)
    w = sb.width - sx;
  if (sy + h > sb.height)
    h = sb.height - sy;
  if (x + w > dst.width)
    w = dst.width - x;
  if (y + h > dst.height)
    h = dst.height - y;
}

// The pixel loop #blt and #blt_quads share: composite src_rect over (x, y)
// at `opacity`. Kept in one place so the batched form cannot drift from the
// single-rect one.
static void blt_pixels(Bitmap& dst,
                       const Bitmap& sb,
                       mrb_int x,
                       mrb_int y,
                       const Rect& rc,
                       int opacity) {
  mrb_int sx = rc.x, sy = rc.y, w = rc.width, h = rc.height;
  if (w <= 0 || h <= 0)
    return;
  // Before any format test below: `sb` may be this same bitmap.
  promote_to_direct(dst);
  // Clip against both bitmaps up front, carrying the destination along with
  // the source the way bmp_copy_blt does. The old loop checked every pixel
  // against both bitmaps instead; iterating only the intersection draws the
  // same set.
  clip_blit(dst, sb, x, y, sx, sy, w, h);
  if (w <= 0 || h <= 0)
    return;

  if (opacity >= 255 && sb.indexed()) {
    for (mrb_int row = 0; row < h; ++row)
      blt_row_indexed(dst, sb, x, y + row, sx, sy + row, w);
    return;
  }

  // Row-copy fast path. Chipset tiles -- the map renderer's rebuild and
  // animation-step hot path through #blt_quads -- are fully opaque rows of
  // plain colour, and for them the per-pixel read/branch/write below is pure
  // overhead: bmp_read/bmp_put re-derive the bytes-per-pixel and redo the
  // bounds checks for every pixel. When both bitmaps share a format, a row
  // whose every alpha byte is 255 is exactly what memcpy puts down (the
  // opaque branch above overwrites the whole pixel including alpha), so copy
  // it in one go; rows with any transparency fall back to the pixel loop.
  if (opacity >= 255 && dst.format == sb.format) {
    const unsigned bpp = pixel_size(dst.format);
    for (mrb_int row = 0; row < h; ++row) {
      const uint8_t* s =
          sb.buffer.data() + ((size_t)(sy + row) * sb.width + sx) * bpp;
      uint8_t* d =
          dst.buffer.data() + ((size_t)(y + row) * dst.width + x) * bpp;
      bool opaque = bpp < 4;
      if (!opaque) {
        opaque = true;
        for (mrb_int col = 0; opaque && col < w; ++col)
          opaque = s[(size_t)col * bpp + 3] == 255;
      }
      if (opaque)
        std::memcpy(d, s, (size_t)w * bpp);
      else
        blt_row_pixels(dst, sb, x, y + row, sx, sy + row, w, opacity);
    }
    return;
  }
  for (mrb_int row = 0; row < h; ++row)
    blt_row_pixels(dst, sb, x, y + row, sx, sy + row, w, opacity);
}

bool deferred_record(Bitmap& dst,
                     const std::shared_ptr<Bitmap>& src,
                     mrb_int x,
                     mrb_int y,
                     const Rect& rc,
                     int opacity,
                     bool copy);

mrb_value bmp_blt(mrb_state* M, V self) {
  mrb_int x, y;
  V src;
  V srect;
  mrb_int opacity = 255;
  mrb_get_args(M, "iioo|i", &x, &y, &src, &srect, &opacity);
  return rgss::bitmap_blt_direct(
      M, self, mrb_int_value(M, x), mrb_int_value(M, y), src, srect,
      mrb_int_value(M, opacity), mrb_get_argc(M) == 5);
}

// Bitmap#blt_quads(x, y, src, quads) -- #blt for a batch of source rects in
// one dispatch. Each element of `quads` is [qdx, qdy, sx, sy, w, h]: the
// rect src[sx,sy,w,h] composited at (x+qdx, y+qdy) with full opacity,
// exactly as an individual #blt call would draw it.
//
// It exists because that batching shape is the map renderer's tile hot
// path. Drawing one chip means several #blt calls (ChipsetLayout#quads),
// and every animation step re-draws every animated cell on the map -- on
// the RPG2000 testbed's water-heavy overworld that is hundreds of mruby
// dispatches plus a Rect allocation apiece, which measured as ~45-60ms
// spikes once per animation step. One dispatch and no Rect objects turns
// the spike back into the per-pixel work itself.
mrb_value bmp_blt_quads(mrb_state* M, V self) {
  mrb_int x, y;
  void* src;
  V quads_v;
  // "A" both fetches the batch and enforces that it is an Array.
  mrb_get_args(M, "iidA", &x, &y, &src, &DataType<Bitmap>::data_type, &quads_v);
  Bitmap& dst = bmp_raw(M, self);
  const std::shared_ptr<Bitmap>& shared = bmp_require_shared(M, src);
  Bitmap& sb = *shared;
  Rect rc;
  const mrb_int n = ary_size(quads_v);
  for (mrb_int i = 0; i < n; ++i) {
    V qv = mrb_ary_ref(M, quads_v, i);
    if (!mrb_array_p(qv) || ary_size(qv) != 6)
      mrb_raisef(M,
                 mrb_class_get_under_id(M, mrb_module_get_id(M, MRB_SYM(RGSS)),
                                        MRB_SYM(RGSSError)),
                 "blt_quads: each quad must be [qdx, qdy, sx, sy, w, h] (%S)",
                 qv);
    V nums[6];
    for (int j = 0; j < 6; ++j) {
      nums[j] = mrb_ary_ref(M, qv, j);
      if (!mrb_integer_p(nums[j]))
        mrb_raisef(
            M,
            mrb_class_get_under_id(M, mrb_module_get_id(M, MRB_SYM(RGSS)),
                                   MRB_SYM(RGSSError)),
            "blt_quads: each quad element must be an Integer (%S)", qv);
    }
    rc.x = mrb_integer(nums[2]);
    rc.y = mrb_integer(nums[3]);
    rc.width = mrb_integer(nums[4]);
    rc.height = mrb_integer(nums[5]);
    const mrb_int qx = x + mrb_integer(nums[0]), qy = y + mrb_integer(nums[1]);
    if (dst.deferred && deferred_record(dst, shared, qx, qy, rc, 255, false))
      continue;
    settle_for_access(sb);
    blt_pixels(dst, sb, qx, qy, rc, 255);
  }
  dst.dirty = true;
  return self;
}

// Bitmap#copy_blt(x, y, src, src_rect) -- put src_rect down at (x, y),
// *replacing* the destination pixels (alpha included) instead of compositing
// over them the way #blt does.
//
// This is not a new blending rule, it is the one case where blending is
// provably a no-op: blend_over() against a fully transparent destination
// returns the source pixel unchanged (dw = 0, out_a = sa), and #blt's own
// alpha>=255 path is already a plain overwrite. So onto a *cleared*
// destination the two show the same picture -- identical alpha everywhere and
// identical colour on every pixel that is visible at all.
//
// They part company on exactly one thing, and it is not observable: for a
// fully transparent source pixel #blt bails out and leaves the cleared black,
// while this copies the source's colour channels over. Nothing can see the
// difference -- blend_over weights the destination by its own alpha, so a
// da == 0 pixel contributes nothing to any later composite, and a fully
// transparent pixel does not render. The mruby-rgss tests assert both halves
// of this over every alpha.
//
// It exists because that case is the map renderer's hot path. Scene::Map#
// draw_layers copies its whole cached tile grid into the frame buffer every
// frame, 336x256 pixels twice, and through #blt's per-pixel read/blend/write
// that measured ~5ms per frame -- a third of the engine's entire 16.67ms
// budget spent blending pixels onto transparency. Row-wise, it is a memcpy.
// #copy_blt's pixel work on an already-resolved pair of bitmaps.
static void copy_pixels(Bitmap& dst,
                        const Bitmap& sb,
                        mrb_int x,
                        mrb_int y,
                        const Rect& rc) {
  // Before the format test below: `sb` may be this same bitmap.
  promote_to_direct(dst);

  mrb_int sx = rc.x, sy = rc.y, w = rc.width, h = rc.height;
  // Clip against the source's origin, carrying the destination along so the
  // two stay in step, then against the destination's, then both extents.
  clip_blit(dst, sb, x, y, sx, sy, w, h);
  if (w <= 0 || h <= 0)
    return;

  if (dst.format == sb.format) {
    const unsigned bpp = pixel_size(dst.format);
    for (mrb_int row = 0; row < h; ++row) {
      const uint8_t* s =
          sb.buffer.data() + ((size_t)(sy + row) * sb.width + sx) * bpp;
      uint8_t* d =
          dst.buffer.data() + ((size_t)(y + row) * dst.width + x) * bpp;
      std::memcpy(d, s, (size_t)w * bpp);
    }
  } else if (sb.indexed()) {
    const unsigned bpp = pixel_size(dst.format);
    for (mrb_int row = 0; row < h; ++row) {
      const uint8_t* s = sb.px() + (size_t)(sy + row) * sb.width + sx;
      uint8_t* d =
          dst.buffer.data() + ((size_t)(y + row) * dst.width + x) * bpp;
      const uint8_t* pal = sb.pal();
      if (bpp == 4) {
        for (mrb_int col = 0; col < w; ++col)
          std::memcpy(d + col * 4, pal + s[col] * 4u, 4);
      } else {
        for (mrb_int col = 0; col < w; ++col)
          std::memcpy(d + col * 3, pal + s[col] * 4u, 3);
      }
    }
  } else {
    // Different pixel formats have no shared byte layout to copy, so go
    // through the accessors -- still a replace, just not a memcpy.
    for (mrb_int row = 0; row < h; ++row) {
      for (mrb_int col = 0; col < w; ++col) {
        int r, g, bl, a;
        bmp_read(sb, sx + col, sy + row, r, g, bl, a);
        bmp_put(dst, x + col, y + row, r, g, bl, a);
      }
    }
  }
}

// `rc_fields` non-null stands in for `srect` (STACK_RECT).
static mrb_value copy_blt_rect(mrb_state* M,
                               V self,
                               mrb_int x,
                               mrb_int y,
                               void* src,
                               V srect,
                               const Rect* rc_fields) {
  Bitmap& dst = bmp_raw(M, self);
  const Rect& rc = rc_fields ? *rc_fields : DataType<Rect>::get(M, srect);
  if (!dst.deferred ||
      !deferred_record(dst, bmp_require_shared(M, src), x, y, rc, 255, true))
    copy_pixels(bmp_self(M, self), bmp_require(M, src), x, y, rc);
  dst.dirty = true;
  return self;
}

mrb_value bmp_copy_blt_body(mrb_state* M,
                            V self,
                            mrb_int x,
                            mrb_int y,
                            void* src,
                            V srect) {
  return copy_blt_rect(M, self, x, y, src, srect, nullptr);
}

mrb_value bmp_copy_blt(mrb_state* M, V self) {
  mrb_int x, y;
  void* src;
  V srect;
  mrb_get_args(M, "iido", &x, &y, &src, &DataType<Bitmap>::data_type, &srect);
  return bmp_copy_blt_body(M, self, x, y, src, srect);
}

// DEFERRED_BITMAP: Bitmap#_defer turns a canvas into a list of the draws made
// on it (clear, fill_rect, blt, blt_quads, copy_blt, stretch_blt, tile_grid,
// and the shinonome draw_text and blend_text), evaluated a few rows at a time
// when a sprite shows it (see DRAW_TIME_SPRITE) instead of being held as
// pixels. Each recorded draw runs later through the very function the immediate
// draw uses (blt_pixels, copy_pixels, fill_pixels, text_stamp, grid_rows) on a
// window of rows, so a row comes out byte for byte as the canvas would have
// held it. Anything else that touches the bitmap materializes it first:
// DataType::get, bmp_require and promote_to_direct all do, and only bmp_raw
// sees the list. Sources stay as they were when drawn: a decoded image is held
// (nothing draws into a loaded asset), a deferred one by a snapshot of its list
// (copy on write), and any other bitmap by a copy of the rect drawn from it.
// RGSS_DEFERRED_BITMAPS=0 (environment or build define) makes _defer a clear.
#ifndef RGSS_DEFERRED_BITMAPS
#define RGSS_DEFERRED_BITMAPS 1
#endif
static bool draw_time_sprites_enabled();
static bool deferred_bitmaps_enabled() {
#if RGSS_DEFERRED_BITMAPS
  static const bool on = [] {
    const char* e = std::getenv("RGSS_DEFERRED_BITMAPS");
    return !(e && std::strcmp(e, "0") == 0);
  }();
  return on && draw_time_sprites_enabled();
#else
  return false;
#endif
}

enum : uint8_t {
  kDeferredBlt,
  kDeferredCopy,
  kDeferredFill,
  kDeferredStretch,
  kDeferredText,
  kDeferredGrid,
  kDeferredDead
};

// One recorded draw, already clipped to its source and destination.
struct DeferredOp {
  int16_t dx, dy;
  // A fill keeps its R, G, B, A bytes in sx and sy, a stretch the index of its
  // rects in sx, a text run that of its glyphs and a tile grid that of its
  // cells; all keep the rows and columns they reach in dx, dy, w, h.
  uint16_t sx, sy, w, h;
  uint16_t src;
  uint8_t opacity, kind;
};

struct DeferredSrc {
  std::shared_ptr<Bitmap> bmp;
  // bmp's draws when it was recorded, if it was deferred; their own sources
  // are never deferred (see deferred_source), so evaluation nests one deep.
  std::shared_ptr<const DeferredList> list;
};

// Rows per band of the index that lets a window of rows visit only the draws
// that reach it.
constexpr int kDeferredBand = 16;
// A list that still holds this many draws after compaction is materialized.
constexpr size_t kDeferredMaxOps = 8192;

// A shinonome text run (see text_layout): the pixels its glyphs set, one bit
// each over its op's rect, and the B, G, R, A bytes each row of the 12px glyph
// cell stores.
struct DeferredText {
  std::vector<uint8_t> mask;  // (w + 7) / 8 bytes a row
  std::array<uint8_t, shinonome::HEIGHT * 4> rows;
  int16_t top;  // the cell's top row
};

static void text_stamp(Bitmap& win,
                       int y0,
                       const DeferredOp& o,
                       const DeferredText& t,
                       int a,
                       int e);

// A list's draws in blocks of kDeferredChunk rather than one array, so a
// layer of thousands of draws never needs one large block, nor the old and the
// new array at once while it grows. The first block grows as a vector does, so
// a list of a few draws stays small.
constexpr size_t kDeferredChunk = 256;
class DeferredOps {
 public:
  size_t size() const { return size_; }
  bool empty() const { return size_ == 0; }
  DeferredOp& operator[](size_t i) {
    return chunks_[i / kDeferredChunk][i % kDeferredChunk];
  }
  const DeferredOp& operator[](size_t i) const {
    return chunks_[i / kDeferredChunk][i % kDeferredChunk];
  }
  void push_back(const DeferredOp& o) {
    if (chunks_.empty() || chunks_.back().size() == kDeferredChunk)
      chunks_.emplace_back();
    std::vector<DeferredOp>& c = chunks_.back();
    // A later block (or a copied one) takes its whole size at once.
    if (chunks_.size() > 1 && c.capacity() < kDeferredChunk)
      c.reserve(kDeferredChunk);
    c.push_back(o);
    ++size_;
  }
  void swap(DeferredOps& o) {
    chunks_.swap(o.chunks_);
    std::swap(size_, o.size_);
  }

 private:
  std::vector<std::vector<DeferredOp>> chunks_;
  size_t size_ = 0;
};

// RPG2000 chip geometry for Bitmap#tile_grid: Game::ChipsetLayout.quads
// (mruby-rpg2k/mrblib/game.rb) for one tile id, as up to four squares.
// mruby-rpg2k/test/test.rb holds the two to the same rects for every id.
struct ChipQuad {
  int16_t dx, dy, sx, sy, size;
};
constexpr int kChip = 16;
constexpr int kHalfChip = 8;
constexpr int16_t kTileNone = INT16_MIN;

// ChipsetLayout::BLOCK_A_SUBTILES and BLOCK_D_SUBTILES.
static const int8_t kChipBlockA[47 * 4] = {
    -1, -1, -1, -1, 3, -1, -1, -1, -1, 3,  -1, -1, 3, 3,  -1, -1, -1, -1, -1,
    3,  3,  -1, -1, 3, -1, 3,  -1, 3,  3,  3,  -1, 3, -1, -1, 3,  -1, 3,  -1,
    3,  -1, -1, 3,  3, -1, 3,  3,  3,  -1, -1, -1, 3, 3,  3,  -1, 3,  3,  -1,
    3,  3,  3,  3,  3, 3,  3,  1,  -1, 1,  -1, 1,  3, 1,  -1, 1,  -1, 1,  3,
    1,  3,  1,  3,  2, 2,  -1, -1, 2,  2,  -1, 3,  2, 2,  3,  -1, 2,  2,  3,
    3,  -1, 1,  -1, 1, -1, 1,  3,  1,  3,  1,  -1, 1, 3,  1,  3,  1,  -1, -1,
    2,  2,  3,  -1, 2, 2,  -1, 3,  2,  2,  3,  3,  2, 2,  1,  1,  1,  1,  2,
    2,  2,  2,  0,  2, 1,  -1, 0,  2,  1,  3,  2,  0, -1, 1,  2,  0,  3,  1,
    -1, 1,  2,  0,  3, 1,  2,  0,  1,  -1, 0,  2,  1, 3,  0,  2,  0,  0,  1,
    1,  0,  2,  0,  2, 1,  1,  0,  0,  2,  0,  2,  0, 0,  0,  0,  0,
};
static const int8_t kChipBlockD[50 * 8] = {
    1, 2, 1, 2, 1, 2, 1, 2, 2, 0, 1, 2, 1, 2, 1, 2, 1, 2, 2, 0, 1, 2, 1, 2, 2,
    0, 2, 0, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 2, 0, 2, 0, 1, 2, 1, 2, 2, 0, 1, 2,
    2, 0, 1, 2, 2, 0, 2, 0, 2, 0, 1, 2, 2, 0, 1, 2, 1, 2, 2, 0, 1, 2, 2, 0, 1,
    2, 2, 0, 1, 2, 1, 2, 2, 0, 2, 0, 1, 2, 2, 0, 2, 0, 2, 0, 1, 2, 1, 2, 1, 2,
    2, 0, 2, 0, 2, 0, 1, 2, 2, 0, 2, 0, 1, 2, 2, 0, 2, 0, 2, 0, 2, 0, 2, 0, 2,
    0, 2, 0, 0, 2, 0, 2, 0, 2, 0, 2, 0, 2, 2, 0, 0, 2, 0, 2, 0, 2, 0, 2, 0, 2,
    2, 0, 0, 2, 2, 0, 0, 2, 2, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2,
    0, 1, 1, 1, 1, 2, 0, 1, 1, 1, 1, 1, 1, 2, 0, 2, 0, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 0, 2, 2, 2, 0, 2, 2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 0, 2, 2, 1,
    3, 1, 3, 1, 3, 1, 3, 2, 0, 1, 3, 1, 3, 1, 3, 1, 3, 2, 0, 1, 3, 1, 3, 2, 0,
    2, 0, 1, 3, 1, 3, 0, 2, 2, 2, 0, 2, 2, 2, 1, 1, 1, 1, 1, 3, 1, 3, 0, 1, 0,
    1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 2, 0, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1,
    2, 0, 2, 1, 2, 3, 2, 3, 2, 3, 2, 3, 2, 0, 2, 3, 2, 3, 2, 3, 0, 3, 0, 3, 0,
    3, 0, 3, 0, 3, 2, 0, 0, 3, 0, 3, 0, 1, 2, 1, 0, 1, 2, 1, 0, 1, 0, 1, 0, 3,
    0, 3, 0, 3, 2, 3, 0, 3, 2, 3, 2, 1, 2, 1, 2, 3, 2, 3, 0, 1, 2, 1, 0, 3, 2,
    3, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0,
};

static int chip_full(int col, int row, ChipQuad* q) {
  q[0] = ChipQuad{0, 0, static_cast<int16_t>(col * kChip),
                  static_cast<int16_t>(row * kChip), kChip};
  return 1;
}

// Quarter k (row k / 2, column k % 2) from that quarter of chip (c[k], r[k]).
static int chip_quarters(const int* c, const int* r, ChipQuad* q) {
  for (int k = 0; k < 4; ++k) {
    const int i = k % 2, j = k / 2;
    q[k] =
        ChipQuad{static_cast<int16_t>(i * kHalfChip),
                 static_cast<int16_t>(j * kHalfChip),
                 static_cast<int16_t>(c[k] * kChip + i * kHalfChip),
                 static_cast<int16_t>(r[k] * kChip + j * kHalfChip), kHalfChip};
  }
  return 4;
}

static int chip_water(int id, int anim, ChipQuad* q) {
  const int set = id / 1000, b = (id % 1000) / 50, a = id % 50;
  if (a >= 47 || b >= 16)
    return 0;
  int c[4], r[4];
  for (int k = 0; k < 4; ++k) {
    const int row = kChipBlockA[a * 4 + k];
    if (row < 0) {
      int t = (b >> k) & 1;
      if (set == 2)
        t ^= 3;
      c[k] = anim;
      r[k] = 4 + t;
    } else {
      c[k] = anim + (set == 1 ? 3 : 0);
      r[k] = row;
    }
  }
  // When both a border and a corner are set, the border quarters win.
  if (b != 0 && a != 0) {
    for (int k = 0; k < 4; ++k) {
      int t = (b >> k) & 1;
      if (set == 2)
        t *= 2;
      if (t != 0) {
        c[k] = anim;
        r[k] = 4 + t;
      }
    }
  }
  return chip_quarters(c, r, q);
}

static int chip_terrain(int id, ChipQuad* q) {
  const int blk = (id - 4000) / 50, sub = (id - 4000) % 50;
  if (blk >= 12)
    return 0;
  const int col = blk < 4 ? (blk % 2) * 3 : 6 + (blk % 2) * 3;
  const int row = blk < 4 ? 8 + (blk / 2) * 4 : ((blk - 4) / 2) * 4;
  int c[4], r[4];
  for (int k = 0; k < 4; ++k) {
    c[k] = col + kChipBlockD[sub * 8 + k * 2];
    r[k] = row + kChipBlockD[sub * 8 + k * 2 + 1];
  }
  return chip_quarters(c, r, q);
}

static int chip_quads(int id, int abf, int cf, ChipQuad* q) {
  if (id < 0)
    return 0;
  if (id >= 10000) {
    const int i = id - 10000;
    if (i >= 144)
      return 0;
    return i < 48 ? chip_full(18 + i % 6, 8 + i / 6, q)
                  : chip_full(24 + (i - 48) % 6, (i - 48) / 6, q);
  }
  if (id >= 5000) {
    const int i = id - 5000;
    if (i >= 144)
      return 0;
    return i < 96 ? chip_full(12 + i % 6, i / 6, q)
                  : chip_full(18 + (i - 96) % 6, (i - 96) / 6, q);
  }
  if (id >= 4000)
    return chip_terrain(id, q);
  if (id >= 3000)
    return chip_full(3 + (id - 3000) / 50, 4 + cf, q);
  return chip_water(id, abf, q);
}

// A Bitmap#tile_grid draw: its chipset, the planes it draws (cols * rows tile
// ids each, in draw order), and the scroll and animation they are drawn at.
struct DeferredGrid {
  std::shared_ptr<Bitmap> chipset;
  std::vector<int16_t> ids;
  int cols, rows, ox, oy, abf, cf, planes;
};

// Draw rows [a, e) of the grid into `win`, whose first row is row y0.
static void grid_rows(Bitmap& win,
                      int y0,
                      const DeferredGrid& g,
                      int a,
                      int e) {
  const size_t n = static_cast<size_t>(g.cols) * g.rows;
  // Integer division rounds toward zero, so these bound the rows from outside.
  const int ry0 = std::max(0, (a + g.oy) / kChip);
  const int ry1 = std::min(g.rows - 1, (e - 1 + g.oy) / kChip);
  ChipQuad q[4];
  for (int ry = ry0; ry <= ry1; ++ry) {
    const int cy = ry * kChip - g.oy;
    for (int rx = 0; rx < g.cols; ++rx) {
      const int cx = rx * kChip - g.ox;
      if (cx + kChip <= 0 || cx >= win.width)
        continue;
      for (int p = 0; p < g.planes; ++p) {
        const int k =
            chip_quads(g.ids[p * n + ry * g.cols + rx], g.abf, g.cf, q);
        for (int i = 0; i < k; ++i) {
          const int qy = cy + q[i].dy;
          const int ya = std::max(qy, a), yb = std::min(qy + q[i].size, e);
          if (ya >= yb)
            continue;
          blt_pixels(win, *g.chipset, cx + q[i].dx, ya - y0,
                     Rect{q[i].sx, q[i].sy + (ya - qy), q[i].size, yb - ya},
                     255);
        }
      }
    }
  }
}

struct DeferredList {
  DeferredOps ops;
  std::vector<DeferredSrc> srcs;
  std::vector<std::vector<uint16_t>> bands;       // op indices, ascending
  std::vector<std::array<int32_t, 8>> stretches;  // destination, source rects
  std::vector<DeferredText> texts;
  std::vector<std::shared_ptr<const DeferredGrid>> grids;
  size_t dead = 0;
};

// Drop b's pixels for an empty draw list, when deferring is on and b asked
// for it.
bool deferred_begin(Bitmap& b) {
  if (!deferred_bitmaps_enabled() || !b.wants_defer)
    return false;
  b.counter() -= b.bytes();
  std::vector<uint8_t>().swap(b.buffer);
  std::vector<uint8_t>().swap(b.palette);
  b.rom_px = b.rom_pal = nullptr;
  b.release_rom();
  b.lazy = false;
  b.format = b.direct_format = kPixelARGB8888;
  b.counter() += b.bytes();
  b.deferred = std::make_shared<DeferredList>();
  return true;
}

static void deferred_index(DeferredList& L, uint16_t i, int height) {
  const DeferredOp& o = L.ops[i];
  if (L.bands.empty())
    L.bands.resize((height + kDeferredBand - 1) / kDeferredBand);
  for (int b = o.dy / kDeferredBand; b <= (o.dy + o.h - 1) / kDeferredBand; ++b)
    L.bands[b].push_back(i);
}

// The list b's draws may be appended to: b's own, or a copy when a snapshot
// elsewhere still shares it.
static DeferredList& deferred_edit(Bitmap& b) {
  if (b.deferred.use_count() > 1)
    b.deferred = std::make_shared<DeferredList>(*b.deferred);
  return *b.deferred;
}

void deferred_clear(Bitmap& b) {
  if (b.deferred.use_count() > 1)
    b.deferred = std::make_shared<DeferredList>();
  else
    *b.deferred = DeferredList{};
}

// #fill_rect's pixel work.
static void fill_put(Bitmap& b,
                     mrb_int x,
                     mrb_int y,
                     mrb_int w,
                     mrb_int h,
                     const Color& c) {
  for (mrb_int j = y; j < y + h; ++j)
    for (mrb_int i = x; i < x + w; ++i)
      bmp_put(b, i, j, c.red, c.green, c.blue, c.alpha);
}

static void stretch_pixels(Bitmap& dst,
                           mrb_int dst_h,
                           mrb_int y_off,
                           const Bitmap& sb,
                           const Rect& dr,
                           const Rect& sr,
                           int opacity);

// Composite rows [y0, y0 + win.height) of a deferred bitmap `height` rows tall
// into `win` (transparent, the bitmap's width).
static void deferred_rows(const DeferredList& L,
                          int height,
                          int y0,
                          Bitmap& win) {
  const int y1 = y0 + win.height;
  const int b0 = std::max(0, y0) / kDeferredBand;
  const int b1 = std::min<int>(static_cast<int>(L.bands.size()) - 1,
                               (std::min(y1, height) - 1) / kDeferredBand);
  if (y1 <= 0 || y0 >= height || b0 > b1)
    return;
  std::vector<uint16_t> merged;
  const std::vector<uint16_t>* order = &L.bands[b0];
  if (b1 > b0) {
    for (int b = b0; b <= b1; ++b)
      merged.insert(merged.end(), L.bands[b].begin(), L.bands[b].end());
    std::sort(merged.begin(), merged.end());
    merged.erase(std::unique(merged.begin(), merged.end()), merged.end());
    order = &merged;
  }
  for (const uint16_t i : *order) {
    const DeferredOp& o = L.ops[i];
    const int a = std::max<int>(o.dy, y0);
    const int e = std::min<int>(o.dy + o.h, y1);
    if (o.kind == kDeferredDead || a >= e)
      continue;
    if (o.kind == kDeferredFill) {
      const Color c{
          static_cast<double>(o.sx >> 8), static_cast<double>(o.sx & 0xff),
          static_cast<double>(o.sy >> 8), static_cast<double>(o.sy & 0xff)};
      fill_put(win, o.dx, a - y0, o.w, e - a, c);
      continue;
    }
    if (o.kind == kDeferredText) {
      text_stamp(win, y0, o, L.texts[o.sx], a, e);
      continue;
    }
    if (o.kind == kDeferredGrid) {
      grid_rows(win, y0, *L.grids[o.sx], a, e);
      continue;
    }
    const DeferredSrc& s = L.srcs[o.src];
    if (o.kind == kDeferredStretch) {
      const std::array<int32_t, 8>& r = L.stretches[o.sx];
      stretch_pixels(win, height, y0, *s.bmp, Rect{r[0], r[1], r[2], r[3]},
                     Rect{r[4], r[5], r[6], r[7]}, o.opacity);
      continue;
    }
    Rect rc{o.sx, o.sy + (a - o.dy), o.w, e - a};
    const Bitmap* sb = s.bmp.get();
    std::unique_ptr<Bitmap> part;
    if (s.list) {
      part = std::make_unique<Bitmap>(sb->width, e - a, kPixelARGB8888);
      deferred_rows(*s.list, sb->height, rc.y, *part);
      rc.y = 0;
      sb = part.get();
    }
    if (o.kind == kDeferredCopy)
      copy_pixels(win, *sb, o.dx, a - y0, rc);
    else
      blt_pixels(win, *sb, o.dx, a - y0, rc, o.opacity);
  }
}

void deferred_materialize(Bitmap& b) {
  // Allocated first: a NoMemoryError leaves `b` deferred.
  std::vector<uint8_t> px;
  const size_t n = static_cast<size_t>(b.width) * b.height * 4;
  pixel_alloc(n, [&] { px.assign(n, 0); });
  std::shared_ptr<DeferredList> L = std::move(b.deferred);
  b.deferred = nullptr;
  b.counter() -= b.bytes();
  b.buffer.swap(px);
  b.counter() += b.bytes();
  if (L && !L->ops.empty())
    deferred_rows(*L, b.height, 0, b);
}

// Whether every pixel of the rect is opaque, so a full-opacity blt of it
// replaces what lies beneath.
static bool rect_opaque(const Bitmap& s, int sx, int sy, int w, int h) {
  if (s.deferred)
    return false;
  if (s.indexed()) {
    for (int y = sy; y < sy + h; ++y)
      for (int x = sx; x < sx + w; ++x)
        if (s.pal()[s.px()[static_cast<size_t>(y) * s.width + x] * 4u + 3] !=
            255)
          return false;
    return true;
  }
  if (pixel_size(s.format) < 4)
    return true;
  for (int y = sy; y < sy + h; ++y)
    for (int x = sx; x < sx + w; ++x)
      if (s.buffer[(static_cast<size_t>(y) * s.width + x) * 4 + 3] != 255)
        return false;
  return true;
}

// The alpha of source pixel (x, y); a deferred source's is unknown, so it
// answers `unknown`.
static int src_alpha(const Bitmap& s, int x, int y, int unknown) {
  if (s.deferred)
    return unknown;
  if (s.indexed())
    return s.pal()[s.px()[static_cast<size_t>(y) * s.width + x] * 4u + 3];
  if (pixel_size(s.format) < 4)
    return 255;
  return s.buffer[(static_cast<size_t>(y) * s.width + x) * 4 + 3];
}

// Whether earlier blt `e`, inside full-opacity blt `o`, has no pixel left that
// `o` does not overwrite: every pixel e changes is opaque in o.
static bool blt_hidden(const DeferredList& L,
                       const DeferredOp& e,
                       const DeferredOp& o) {
  const Bitmap& es = *L.srcs[e.src].bmp;
  const Bitmap& os = *L.srcs[o.src].bmp;
  for (int y = 0; y < e.h; ++y) {
    for (int x = 0; x < e.w; ++x) {
      if (src_alpha(es, e.sx + x, e.sy + y, 255) * e.opacity / 255 <= 0)
        continue;
      if (src_alpha(os, o.sx + (e.dx - o.dx) + x, o.sy + (e.dy - o.dy) + y,
                    0) != 255)
        return false;
    }
  }
  return true;
}

// Drop the earlier draws inside a new one that it replaces: all of them for a
// copy, a fill or an opaque blt, and for any other full-opacity blt those
// whose every changed pixel it overwrites.
static void deferred_cover(DeferredList& L,
                           const DeferredOp& o,
                           bool opaque,
                           int height) {
  if (L.bands.empty() || o.kind == kDeferredStretch ||
      o.kind == kDeferredText || o.kind == kDeferredGrid ||
      (o.kind == kDeferredBlt && o.opacity < 255))
    return;
  for (int b = o.dy / kDeferredBand; b <= (o.dy + o.h - 1) / kDeferredBand;
       ++b) {
    for (const uint16_t i : L.bands[b]) {
      DeferredOp& e = L.ops[i];
      if (e.kind != kDeferredDead && e.dx >= o.dx && e.dy >= o.dy &&
          e.dx + e.w <= o.dx + o.w && e.dy + e.h <= o.dy + o.h &&
          (opaque || (e.kind == kDeferredBlt && blt_hidden(L, e, o)))) {
        e.kind = kDeferredDead;
        ++L.dead;
      }
    }
  }
}

// Rebuild the list without its dropped draws once they are the majority.
static void deferred_compact(DeferredList& L, int height, bool full = false) {
  if (full ? L.dead == 0 : (L.dead < 8 || L.dead * 2 < L.ops.size()))
    return;
  DeferredOps live;
  std::vector<int> remap(L.srcs.size(), -1);
  std::vector<DeferredSrc> srcs;
  std::vector<std::array<int32_t, 8>> stretches;
  std::vector<DeferredText> texts;
  std::vector<std::shared_ptr<const DeferredGrid>> grids;
  for (size_t k = 0; k < L.ops.size(); ++k) {
    DeferredOp e = L.ops[k];
    if (e.kind == kDeferredDead)
      continue;
    if (e.kind == kDeferredStretch) {
      stretches.push_back(L.stretches[e.sx]);
      e.sx = static_cast<uint16_t>(stretches.size() - 1);
    }
    if (e.kind == kDeferredText) {
      texts.push_back(std::move(L.texts[e.sx]));
      e.sx = static_cast<uint16_t>(texts.size() - 1);
    }
    if (e.kind == kDeferredGrid) {
      grids.push_back(std::move(L.grids[e.sx]));
      e.sx = static_cast<uint16_t>(grids.size() - 1);
    }
    if (e.kind != kDeferredFill && e.kind != kDeferredText &&
        e.kind != kDeferredGrid) {
      if (remap[e.src] < 0) {
        remap[e.src] = static_cast<int>(srcs.size());
        srcs.push_back(L.srcs[e.src]);
      }
      e.src = static_cast<uint16_t>(remap[e.src]);
    }
    live.push_back(e);
  }
  L.ops.swap(live);
  L.srcs.swap(srcs);
  L.stretches.swap(stretches);
  L.texts.swap(texts);
  L.grids.swap(grids);
  L.dead = 0;
  L.bands.clear();
  for (size_t i = 0; i < L.ops.size(); ++i)
    deferred_index(L, static_cast<uint16_t>(i), height);
}

// Append a recorded draw; a list that stays full afterwards is materialized,
// draw included.
static bool deferred_push(Bitmap& b, DeferredOp o, bool opaque) {
  DeferredList& L = deferred_edit(b);
  deferred_cover(L, o, opaque, b.height);
  L.ops.push_back(o);
  deferred_index(L, static_cast<uint16_t>(L.ops.size() - 1), b.height);
  deferred_compact(L, b.height);
  if (L.ops.size() >= kDeferredMaxOps)
    deferred_compact(L, b.height, /* full = */ true);
  if (L.ops.size() >= kDeferredMaxOps) {
    std::fprintf(stderr,
                 "[RGSS] deferred %dx%d bitmap reached %zu draws; keeping its "
                 "pixels until it is next cleared\n",
                 static_cast<int>(b.width), static_cast<int>(b.height),
                 L.ops.size());
    deferred_materialize(b);
  }
  return true;
}

// The source slot for a draw from `s` of the clipped rect (sx, sy, w, h); a
// copied source moves the rect to its own origin.
static uint16_t deferred_source(DeferredList& L,
                                const std::shared_ptr<Bitmap>& s,
                                mrb_int& sx,
                                mrb_int& sy,
                                mrb_int w,
                                mrb_int h) {
  if (s->deferred || s->decoded_from_source) {
    const DeferredSrc want{s, s->deferred};
    for (size_t i = L.srcs.size(); i-- > 0;)
      if (L.srcs[i].bmp == want.bmp && L.srcs[i].list == want.list)
        return static_cast<uint16_t>(i);
    L.srcs.push_back(want);
    return static_cast<uint16_t>(L.srcs.size() - 1);
  }
  auto part = std::make_shared<Bitmap>(w, h, s->format);
  if (s->indexed())
    part->palette.assign(s->pal(), s->pal() + 256 * 4);
  part->direct_format = s->direct_format;
  part->counter() += part->palette.size();
  const unsigned bpp = pixel_size(s->format);
  for (mrb_int y = 0; y < h; ++y)
    std::memcpy(part->buffer.data() + static_cast<size_t>(y) * w * bpp,
                s->px() + (static_cast<size_t>(sy + y) * s->width + sx) * bpp,
                static_cast<size_t>(w) * bpp);
  sx = 0;
  sy = 0;
  L.srcs.push_back(DeferredSrc{std::move(part), nullptr});
  return static_cast<uint16_t>(L.srcs.size() - 1);
}

// Record a blt (or, with `copy`, a copy_blt) of src's `rc` at (x, y) into the
// deferred `dst`. Returns false when the draw has to be made on the pixels
// instead: a bitmap drawn into itself.
bool deferred_record(Bitmap& dst,
                     const std::shared_ptr<Bitmap>& src,
                     mrb_int x,
                     mrb_int y,
                     const Rect& rc,
                     int opacity,
                     bool copy) {
  if (src.get() == &dst)
    return false;
  mrb_int sx = rc.x, sy = rc.y, w = rc.width, h = rc.height;
  if (w <= 0 || h <= 0)
    return true;
  clip_blit(dst, *src, x, y, sx, sy, w, h);
  if (w <= 0 || h <= 0 || (!copy && opacity <= 0))
    return true;
  // A deferred source must not draw from another deferred bitmap itself.
  if (src->deferred) {
    for (const DeferredSrc& d : src->deferred->srcs)
      if (d.list) {
        deferred_materialize(*src);
        break;
      }
  }
  const bool opaque =
      copy || (opacity >= 255 && rect_opaque(*src, sx, sy, w, h));
  DeferredList& L = deferred_edit(dst);
  const uint16_t slot = deferred_source(L, src, sx, sy, w, h);
  DeferredOp o{static_cast<int16_t>(x),
               static_cast<int16_t>(y),
               static_cast<uint16_t>(sx),
               static_cast<uint16_t>(sy),
               static_cast<uint16_t>(w),
               static_cast<uint16_t>(h),
               slot,
               static_cast<uint8_t>(opacity),
               copy ? kDeferredCopy : kDeferredBlt};
  return deferred_push(dst, o, opaque);
}

void fill_pixels(Bitmap& b,
                 mrb_int x,
                 mrb_int y,
                 mrb_int w,
                 mrb_int h,
                 const Color& c) {
  if (!b.deferred && x <= 0 && y <= 0 && x + w >= b.width && y + h >= b.height)
    deferred_begin(b);
  if (b.deferred) {
    // bmp_put's own clip, applied up front.
    const mrb_int x0 = std::max<mrb_int>(x, 0), y0 = std::max<mrb_int>(y, 0);
    const mrb_int x1 = std::min<mrb_int>(x + w, b.width);
    const mrb_int y1 = std::min<mrb_int>(y + h, b.height);
    if (x0 >= x1 || y0 >= y1)
      return;
    // The bytes bmp_put stores.
    const uint16_t bg = static_cast<uint16_t>(static_cast<uint8_t>(c.red) << 8 |
                                              static_cast<uint8_t>(c.green));
    const uint16_t ba = static_cast<uint16_t>(
        static_cast<uint8_t>(c.blue) << 8 | static_cast<uint8_t>(c.alpha));
    DeferredOp o{static_cast<int16_t>(x0),
                 static_cast<int16_t>(y0),
                 bg,
                 ba,
                 static_cast<uint16_t>(x1 - x0),
                 static_cast<uint16_t>(y1 - y0),
                 0,
                 0,
                 kDeferredFill};
    deferred_push(b, o, true);
    return;
  }
  fill_put(b, x, y, w, h, c);
}

// Record a stretch_blt of src's `sr` over `dr` into the deferred `dst`, as
// deferred_record does a blt.
bool deferred_stretch(Bitmap& dst,
                      const std::shared_ptr<Bitmap>& src,
                      const Rect& dr,
                      const Rect& sr,
                      int opacity) {
  if (src.get() == &dst)
    return false;
  const mrb_int x0 = std::max<mrb_int>(dr.x, 0),
                y0 = std::max<mrb_int>(dr.y, 0);
  const mrb_int x1 = std::min<mrb_int>(dr.x + dr.width, dst.width);
  const mrb_int y1 = std::min<mrb_int>(dr.y + dr.height, dst.height);
  if (opacity <= 0 || x0 >= x1 || y0 >= y1)
    return true;
  settle_for_access(*src);
  std::array<int32_t, 8> r{
      static_cast<int32_t>(dr.x),     static_cast<int32_t>(dr.y),
      static_cast<int32_t>(dr.width), static_cast<int32_t>(dr.height),
      static_cast<int32_t>(sr.x),     static_cast<int32_t>(sr.y),
      static_cast<int32_t>(sr.width), static_cast<int32_t>(sr.height)};
  DeferredList& L = deferred_edit(dst);
  uint16_t slot;
  if (src->decoded_from_source) {
    mrb_int sx = 0, sy = 0;
    slot = deferred_source(L, src, sx, sy, 0, 0);
  } else {
    // Only the part of `sr` inside the source is ever read.
    mrb_int ix = std::max<mrb_int>(sr.x, 0), iy = std::max<mrb_int>(sr.y, 0);
    const mrb_int iw = std::min<mrb_int>(sr.x + sr.width, src->width) - ix;
    const mrb_int ih = std::min<mrb_int>(sr.y + sr.height, src->height) - iy;
    if (iw <= 0 || ih <= 0)
      return true;
    r[4] -= static_cast<int32_t>(ix);
    r[5] -= static_cast<int32_t>(iy);
    slot = deferred_source(L, src, ix, iy, iw, ih);
  }
  L.stretches.push_back(r);
  DeferredOp o{static_cast<int16_t>(x0),
               static_cast<int16_t>(y0),
               static_cast<uint16_t>(L.stretches.size() - 1),
               0,
               static_cast<uint16_t>(x1 - x0),
               static_cast<uint16_t>(y1 - y0),
               slot,
               static_cast<uint8_t>(opacity),
               kDeferredStretch};
  return deferred_push(dst, o, false);
}

// The chipset a recorded grid reads: a decoded image as it is, anything else
// as a copy, as deferred_source keeps a blt's source.
static std::shared_ptr<Bitmap> grid_chipset(const std::shared_ptr<Bitmap>& s) {
  if (s->decoded_from_source && !s->deferred)
    return s;
  settle_for_access(*s);
  auto c = std::make_shared<Bitmap>(s->width, s->height, s->format);
  if (s->indexed())
    c->palette.assign(s->pal(), s->pal() + 256 * 4);
  c->direct_format = s->direct_format;
  c->counter() += c->palette.size();
  std::memcpy(
      c->buffer.data(), s->px(),
      static_cast<size_t>(s->width) * s->height * pixel_size(s->format));
  return c;
}

// Bitmap#tile_grid(chipset, cells, ox, oy, abf, cf, upper) -- an RPG2000 map
// layer in one draw. `cells` is a cols x rows x 3 Table of tile ids: cell
// (x, y) is drawn at (x * 16 - ox, y * 16 - oy) from `chipset`, as
// Game::ChipsetLayout.quads(id, abf, cf) lays it out, planes 0 then 1 unless
// `upper`, plane 2 if it is. -32768 draws nothing. A deferred bitmap records
// it as one draw over a copy of those planes instead of a draw per chip.
mrb_value bmp_tile_grid(mrb_state* M, V self) {
  void* src;
  V cells_v;
  mrb_int ox, oy, abf, cf;
  mrb_bool upper;
  mrb_get_args(M, "doiiiib", &src, &DataType<Bitmap>::data_type, &cells_v, &ox,
               &oy, &abf, &cf, &upper);
  Bitmap& dst = bmp_raw(M, self);
  const std::shared_ptr<Bitmap>& sb = bmp_require_shared(M, src);
  const Table& t = DataType<Table>::get(M, cells_v);
  if (t.zsize != 3)
    mrb_raise(M,
              mrb_class_get_under_id(M, mrb_module_get_id(M, MRB_SYM(RGSS)),
                                     MRB_SYM(RGSSError)),
              "tile_grid: cells must be a Table of 3 planes");
  auto g = std::make_shared<DeferredGrid>();
  g->cols = t.xsize;
  g->rows = t.ysize;
  g->ox = static_cast<int>(ox);
  g->oy = static_cast<int>(oy);
  g->abf = static_cast<int>(abf);
  g->cf = static_cast<int>(cf);
  g->planes = upper ? 1 : 2;
  const size_t n = static_cast<size_t>(t.xsize) * t.ysize;
  const auto first = t.data.begin() + (upper ? 2 * n : 0);
  g->ids.assign(first, first + g->planes * n);
  dst.dirty = true;
  const mrb_int x0 = std::max<mrb_int>(-ox, 0), y0 = std::max<mrb_int>(-oy, 0);
  const mrb_int x1 = std::min<mrb_int>(g->cols * kChip - ox, dst.width);
  const mrb_int y1 = std::min<mrb_int>(g->rows * kChip - oy, dst.height);
  if (x0 >= x1 || y0 >= y1 ||
      std::all_of(g->ids.begin(), g->ids.end(),
                  [](int16_t id) { return id == kTileNone; }))
    return self;
  if (dst.deferred && sb.get() != &dst) {
    g->chipset = grid_chipset(sb);
    DeferredList& L = deferred_edit(dst);
    L.grids.push_back(std::move(g));
    DeferredOp o{static_cast<int16_t>(x0),
                 static_cast<int16_t>(y0),
                 static_cast<uint16_t>(L.grids.size() - 1),
                 0,
                 static_cast<uint16_t>(x1 - x0),
                 static_cast<uint16_t>(y1 - y0),
                 0,
                 255,
                 kDeferredGrid};
    deferred_push(dst, o, false);
    return self;
  }
  Bitmap& d = bmp_self(M, self);
  settle_for_access(*sb);
  g->chipset = sb;
  grid_rows(d, 0, *g, static_cast<int>(y0), static_cast<int>(y1));
  return self;
}

// Bitmap#_defer(on = true): drop the pixels and record later draws (see
// DEFERRED_BITMAP); _defer(false) turns a deferred bitmap back into the pixels
// it shows.
mrb_value bmp_defer(mrb_state* M, V self) {
  mrb_bool on = true;
  mrb_get_args(M, "|b", &on);
  Bitmap& b = bmp_raw(M, self);
  b.wants_defer = on;
  if (!on) {
    settle_for_access(b);
    return self;
  }
  if (!deferred_begin(b) && !b.lazy) {
    promote_to_direct(b, /* keep = */ false);
    std::fill(b.buffer.begin(), b.buffer.end(), 0);
  }
  b.dirty = true;
  return self;
}

// Copy src_rect from `src` into dest_rect of self, scaling with nearest
// neighbour sampling. Mirrors RGSS's Bitmap#stretch_blt and is used to stretch
// the small windowskin pieces (32x32 background, 16x8/8x16 border edges) over
// an arbitrarily sized window.
mrb_value bmp_stretch_blt_body(mrb_state* M,
                               mrb_value self,
                               mrb_value drect_v,
                               void* src,
                               mrb_value srect_v,
                               mrb_value opacity_value,
                               mrb_bool opacity_given);

mrb_value bmp_stretch_blt(mrb_state* M, V self) {
  V drect_v, srect_v;
  void* src;
  mrb_int opacity = 255;
  mrb_get_args(M, "odo|i", &drect_v, &src, &DataType<Bitmap>::data_type,
               &srect_v, &opacity);
  return bmp_stretch_blt_body(M, self, drect_v, src, srect_v,
                              mrb_int_value(M, opacity), mrb_get_argc(M) == 4);
}

// #stretch_blt's pixel work for the rows of `dr` that land on rows
// [y_off, y_off + dst.height) of a bitmap `dst_h` rows tall: the whole of
// `dst` when y_off is 0 and dst_h is its height.
static void stretch_pixels(Bitmap& dst,
                           mrb_int dst_h,
                           mrb_int y_off,
                           const Bitmap& sb,
                           const Rect& dr,
                           const Rect& sr,
                           int opacity) {
  for (mrb_int j = 0; j < dr.height; ++j) {
    const mrb_int dy_full = dr.y + j;
    if (dy_full < 0 || dy_full >= dst_h)
      continue;
    const mrb_int dy = dy_full - y_off;
    if (dy < 0 || dy >= dst.height)
      continue;
    const mrb_int sy = sr.y + j * sr.height / dr.height;
    for (mrb_int i = 0; i < dr.width; ++i) {
      const mrb_int dx = dr.x + i;
      if (dx < 0 || dx >= dst.width)
        continue;
      const mrb_int sx = sr.x + i * sr.width / dr.width;
      if (sx < 0 || sy < 0 || sx >= sb.width || sy >= sb.height)
        continue;
      int r, g, bl, a;
      bmp_read(sb, sx, sy, r, g, bl, a);
      const int alpha = a * opacity / 255;
      if (alpha <= 0)
        continue;
      if (alpha >= 255) {
        bmp_put(dst, dx, dy, r, g, bl, 255);
        continue;
      }
      int dr2, dg, db, da;
      bmp_read(dst, dx, dy, dr2, dg, db, da);
      blend_over(dst, dx, dy, r, g, bl, alpha, dr2, dg, db, da);
    }
  }
}

bool deferred_stretch(Bitmap& dst,
                      const std::shared_ptr<Bitmap>& src,
                      const Rect& dr,
                      const Rect& sr,
                      int opacity);

// A non-null `dr_fields` / `sr_fields` stands in for that Rect argument
// (STACK_RECT, bitmap_stretch_blt_rects_direct).
static mrb_value stretch_blt_rects(mrb_state* M,
                                   mrb_value self,
                                   mrb_value drect_v,
                                   const Rect* dr_fields,
                                   void* src,
                                   mrb_value srect_v,
                                   const Rect* sr_fields,
                                   mrb_value opacity_value,
                                   mrb_bool opacity_given) {
  mrb_int opacity = opacity_given ? mrb_as_int(M, opacity_value) : 255;
  Bitmap& dst = bmp_raw(M, self);
  const Rect& dr = dr_fields ? *dr_fields : DataType<Rect>::get(M, drect_v);
  const Rect& sr = sr_fields ? *sr_fields : DataType<Rect>::get(M, srect_v);
  if (opacity < 0)
    opacity = 0;
  if (opacity > 255)
    opacity = 255;
  if (dr.width <= 0 || dr.height <= 0 || sr.width <= 0 || sr.height <= 0)
    return self;
  if (!dst.deferred || !deferred_stretch(dst, bmp_require_shared(M, src), dr,
                                         sr, static_cast<int>(opacity))) {
    Bitmap& d = bmp_self(M, self);
    stretch_pixels(d, d.height, 0, bmp_require(M, src), dr, sr,
                   static_cast<int>(opacity));
  }
  dst.dirty = true;
  return self;
}

mrb_value bmp_stretch_blt_body(mrb_state* M,
                               mrb_value self,
                               mrb_value drect_v,
                               void* src,
                               mrb_value srect_v,
                               mrb_value opacity_value,
                               mrb_bool opacity_given) {
  return stretch_blt_rects(M, self, drect_v, nullptr, src, srect_v, nullptr,
                           opacity_value, opacity_given);
}

// RGSS-adjacent Bitmap#mosaic_blt(src, block_size): copy `src` into this
// bitmap, same size, resampled into `block_size`x`block_size` pixel blocks
// (nearest-neighbour, one sample per block) -- the Erase/Show Screen Mosaic
// styles' per-frame resample.
//
// This is a native pass, not a Ruby one, because RPG2000's own Mosaic
// dissolves the *whole* screen every frame: a get_pixel/set_pixel loop over
// 76800 pixels in Ruby is far too slow to run once per frame, let alone once
// per block-size step across a 41-frame transition (see docs/TODO.md's
// "Screen effects" entry).
//
// Ported from a reference implementation's mosaic-transition case, not
// independently confirmed against genuine RPG_RT under wine: each output
// pixel samples the pixel nearest the centre of its `block_size`x`block_size`
// block -- `off = block_size / 2`, `src = clamp(((pos + off) / block_size) *
// block_size - off, 0, len - 1)` on each axis -- rather than a block average,
// which is why a 1px block is the identity (`off` is 0, `src == pos`). RPG_RT
// also nudges the sampling window by a small per-frame random offset (its own
// `mosaic_random_offset`, resized and filled once per transition from
// `Rand::GetRandomNumber(0, i)`); this port omits that jitter, sampling the
// same block centre deterministically every time, which keeps the geometry
// (`Game::Transition#mosaic_block_size`, mruby-rpg2k/mrblib/game.rb) pure and
// unit-testable without threading RNG state through it -- the same kind of
// reasoned simplification the random-blocks Down/Up bias and the cross
// combine/division quadrant motion already are elsewhere in that class.
mrb_value bmp_mosaic_blt(mrb_state* M, V self) {
  Bitmap& dst = bmp_self(M, self);
  V src_v;
  mrb_int size;
  mrb_get_args(M, "oi", &src_v, &size);
  Bitmap& src = DataType<Bitmap>::get(M, src_v);

  if (src.width != dst.width || src.height != dst.height) {
    RClass* mod = mrb_module_get_id(M, MRB_SYM(RGSS));
    RClass* err = mrb_class_get_under_id(M, mod, MRB_SYM(RGSSError));
    mrb_raisef(M, err, "mosaic_blt: size mismatch (self %dx%d, src %dx%d)",
               dst.width, dst.height, src.width, src.height);
  }
  const int32_t blk = size < 1 ? 1 : static_cast<int32_t>(size);
  const int32_t off = blk / 2;
  // The pixel nearest the centre of the block `pos` falls in, clamped onto
  // the bitmap -- see the port note above for the RPG_RT jitter this omits.
  auto block_centre = [&](int32_t pos, int32_t len) {
    return std::clamp<int32_t>(((pos + off) / blk) * blk - off, 0, len - 1);
  };
  for (int32_t y = 0; y < src.height; ++y) {
    const int32_t sy = block_centre(y, src.height);
    for (int32_t x = 0; x < src.width; ++x) {
      const int32_t sx = block_centre(x, src.width);
      int r, g, bl, a;
      bmp_read(src, sx, sy, r, g, bl, a);
      bmp_put(dst, x, y, r, g, bl, a);
    }
  }
  dst.dirty = true;
  return self;
}

// RGSS-adjacent Bitmap#wave_blt(src, depth, phase): blit `src` into this
// bitmap, same size, each scanline displaced horizontally by a sine wave --
// the Erase/Show Screen Wave styles' per-frame resample. Pixels a shifted row
// no longer covers are left as whatever is already in `self` (the caller
// fills black first, matching RPG_RT drawing the wave over a cleared frame).
//
// Ported from a reference implementation's wave-blit routine, not
// independently confirmed against genuine RPG_RT under wine, as called from
// its wave-transition case with no scale (`zoom_x = zoom_y = 1`): row `y`'s
// offset is `trunc(2 * depth * sin(phase + y * 2*pi / 32))`, `depth`/`phase`
// supplied per frame by `Game::Transition#wave_params`
// (mruby-rpg2k/mrblib/game.rb), itself the same `p * 5 * pi / tf_off + pi`
// ramp that reference implementation's own transition code computes.
mrb_value bmp_wave_blt(mrb_state* M, V self) {
  Bitmap& dst = bmp_self(M, self);
  V src_v;
  mrb_int depth;
  mrb_value phase_v;
  mrb_get_args(M, "oio", &src_v, &depth, &phase_v);
  const double phase = rgss::fraction_arg(M, phase_v);
  Bitmap& src = DataType<Bitmap>::get(M, src_v);

  if (src.width != dst.width || src.height != dst.height) {
    RClass* mod = mrb_module_get_id(M, MRB_SYM(RGSS));
    RClass* err = mrb_class_get_under_id(M, mod, MRB_SYM(RGSSError));
    mrb_raisef(M, err, "wave_blt: size mismatch (self %dx%d, src %dx%d)",
               dst.width, dst.height, src.width, src.height);
  }

  constexpr double two_pi = 2.0 * 3.14159265358979323846;
  for (int32_t y = 0; y < src.height; ++y) {
    const double sy = y * two_pi / 32.0;
    const int32_t offset = static_cast<int32_t>(
        2.0 * static_cast<double>(depth) * std::sin(phase + sy));
    for (int32_t x = 0; x < src.width; ++x) {
      const int32_t dx = x + offset;
      if (dx < 0 || dx >= dst.width)
        continue;
      int r, g, bl, a;
      bmp_read(src, x, y, r, g, bl, a);
      if (a <= 0)
        continue;
      if (a >= 255) {
        bmp_put(dst, dx, y, r, g, bl, 255);
        continue;
      }
      int dr, dg, db, da;
      bmp_read(dst, dx, y, dr, dg, db, da);
      blend_over(dst, dx, y, r, g, bl, a, dr, dg, db, da);
    }
  }
  dst.dirty = true;
  return self;
}

auto find_char = [](char32_t c, const auto* g, unsigned g_len) -> const auto* {
  auto i = std::lower_bound(g, g + g_len, c, [](const auto& e, char32_t v) {
    return e.codepoint < v;
  });
  if (i == (g + g_len))
    return static_cast<decltype(i)>(nullptr);
  if (i->codepoint != c)
    return static_cast<decltype(i)>(nullptr);
  return i;
};

// The JIS0208 GOTHIC face is 165,624 bytes flash (real
// measurement) -- by far the single largest piece of static data
// mruby-rgss carries, and RGSS_SHINONOME_GOTHIC_SD_PATH (a no-op unless
// defined) moves it to the SD card instead: gen_shinonome_data.rb's own
// SHINONOME_GOTHIC_SD_FILE writes the same sorted (codepoint, bitmap) pairs
// find_char above already binary-searches, as flat packed binary, to a file
// this reads back with plain std::fopen/fseek/fread -- the same file API
// bmp_init_file already uses for every game asset, on every target
// including wio, so this needs no new HAL. Unlike mruby-rpg2k's compiled
// Ruby (an earlier attempt, abandoned once RAM-scaling made it
// impractical), a glyph bitmap is raw data with a fixed, tiny per-entry
// size -- no mrb_load_irep_buf, no interpreter IREP overhead, no cost that
// scales with how much of the face is "loaded": binary search touches
// O(log n) records, and a small fixed-size cache (shinonome_sd::Cache below)
// keeps every glyph a session actually draws resident after its first,
// one-time SD read, so a dialogue box that reuses the same few hundred
// kanji over and over reads the card once per glyph, not once per frame.
#ifdef RGSS_SHINONOME_GOTHIC_SD_PATH
namespace shinonome_sd {

using GothicChar = shinonome::Char<shinonome::HEIGHT>;
// Mirrors shinonome.hxx's own std::array<uint32_t, PIXELS/32 + ...> sizing
// for Char::data exactly, so a record here is byte-for-byte the same shape
// gen_shinonome_data.rb's SHINONOME_GOTHIC_SD_FILE writer emits.
constexpr unsigned GOTHIC_WORDS =
    GothicChar::PIXELS / 32 + ((GothicChar::PIXELS % 32) > 0 ? 1 : 0);

// Fixed-size, direct-mapped cache: CAPACITY slots, replaced round-robin as
// new glyphs are looked up. Not an LRU (no per-access bookkeeping) -- with
// a few dozen distinct kanji in an ordinary dialogue box, a round-robin
// still keeps the working set resident far more often than it evicts it,
// and costs nothing to maintain per lookup. 64, not a rounder-looking 256:
// each slot is sizeof(GothicChar) (24 bytes) of static BSS, and a real
// relink at 256 slots overflowed the
// board's 192 KB RAM budget by 248 bytes -- this board has none to spare
// for a cache size picked without checking.
struct Cache {
  static constexpr unsigned CAPACITY = 64;
  std::array<GothicChar, CAPACITY> slots{};
  unsigned next = 0;
  std::FILE* fp = nullptr;
  bool tried_open = false;
  uint32_t count = 0;

  Cache() {
    for (auto& s : slots)
      s.codepoint = 0xffffffffu;  // never a real Unicode codepoint
  }

  static uint32_t read_u32le(std::FILE* f) {
    uint8_t b[4];
    if (std::fread(b, 1, 4, f) != 4)
      return 0;
    return static_cast<uint32_t>(b[0]) | (static_cast<uint32_t>(b[1]) << 8) |
           (static_cast<uint32_t>(b[2]) << 16) |
           (static_cast<uint32_t>(b[3]) << 24);
  }

  bool ensure_open() {
    if (tried_open)
      return fp != nullptr;
    tried_open = true;
    fp = std::fopen(RGSS_SHINONOME_GOTHIC_SD_PATH, "rb");
    if (!fp)
      return false;
    count = read_u32le(fp);
    return true;
  }

  const GothicChar* find(char32_t c) {
    for (const auto& s : slots)
      if (s.codepoint == c)
        return &s;

    if (!ensure_open())
      return nullptr;

    constexpr long kRecordSize = 4 + GOTHIC_WORDS * 4;
    long lo = 0, hi = static_cast<long>(count);
    while (lo < hi) {
      const long mid = lo + (hi - lo) / 2;
      std::fseek(fp, 4 + mid * kRecordSize, SEEK_SET);
      const uint32_t cp = read_u32le(fp);
      if (cp == c) {
        GothicChar& slot = slots[next];
        next = (next + 1) % CAPACITY;
        slot.codepoint = c;
        for (auto& word : slot.data)
          word = read_u32le(fp);
        return &slot;
      }
      if (cp < c)
        lo = mid + 1;
      else
        hi = mid;
    }
    return nullptr;
  }
};

Cache g_cache;

}  // namespace shinonome_sd
#endif  // RGSS_SHINONOME_GOTHIC_SD_PATH

// Every real call site already reads shinonome::GOTHIC through find_char
// directly; route them all through here instead so the SD fallback above is
// one place, not three. Checks the (possibly now-empty, see
// gen_shinonome_data.rb) compiled-in table first -- a build that never
// defined RGSS_SHINONOME_GOTHIC_SD_PATH behaves exactly as before, and one
// that did but shipped some glyphs in flash anyway (a partial
// SHINONOME_GLYPH_TEXT_FILE allow-list, say) never pays for an SD lookup on
// those.
const shinonome::Char<shinonome::HEIGHT>* find_gothic_char(char32_t c) {
  auto* f = find_char(c, shinonome::GOTHIC, shinonome::GOTHIC_LEN);
  if (f)
    return f;
#ifdef RGSS_SHINONOME_GOTHIC_SD_PATH
  return shinonome_sd::g_cache.find(c);
#else
  return nullptr;
#endif
}

// --- TrueType text rendering -------------------------------------------------
//
// RPG Maker XP/VX projects ship their UI font as a TrueType/OpenType file under
// the game's `Fonts/` folder and select it by family name through RGSS::Font.
// We rasterise those glyphs with stb_truetype so window/menu/title text honours
// the font's pixel size (plus bold/italic/outline/shadow), instead of the
// fixed-size shinonome bitmap font. When no usable font file is found we fall
// back to the shinonome path below, so text always draws.
//
// Compiled out on wio: it has no Fonts/ directory to scan (no
// dirent) and no maker that sets RGSS::Font.default_path, so every face
// lookup there fails and text is always shinonome.

#if !defined(WIO_TERMINAL)
struct TtfFont {
  std::vector<uint8_t> data;
  stbtt_fontinfo info{};
  bool ok = false;
};

// Lowercased, alphanumeric-only copy of a font name, so a family such as
// "VL Gothic" leniently matches a file like "VL-Gothic-Regular.ttf".
std::string font_key(std::string_view s) {
  std::string r;
  for (const unsigned char c : s)
    if (std::isalnum(c))
      r.push_back(static_cast<char>(std::tolower(c)));
  return r;
}

bool has_font_ext(const std::string& name) {
  if (name.size() < 4)
    return false;
  std::string ext = name.substr(name.size() - 4);
  for (char& c : ext)
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return ext == ".ttf" || ext == ".otf" || ext == ".ttc";
}

// Value of a String constant on Object (GAME_DIR / RTP_DIR), or "" when it is
// unset or not a String.
std::string object_const_str(mrb_state* M, const char* name) {
  const mrb_sym sym = mrb_intern_cstr(M, name);
  const V obj = mrb_obj_value(M->object_class);
  if (!mrb_const_defined(M, obj, sym))
    return std::string();
  const V v = mrb_const_get(M, obj, sym);
  if (!mrb_string_p(v))
    return std::string();
  return std::string(RSTRING_PTR(v), RSTRING_LEN(v));
}

std::shared_ptr<TtfFont> load_ttf(const std::string& path) {
  auto f = std::make_shared<TtfFont>();
  std::FILE* fp = std::fopen(path.c_str(), "rb");
  if (!fp)
    return f;
  std::fseek(fp, 0, SEEK_END);
  const long sz = std::ftell(fp);
  std::fseek(fp, 0, SEEK_SET);
  if (sz > 0) {
    f->data.resize(static_cast<size_t>(sz));
    if (std::fread(f->data.data(), 1, static_cast<size_t>(sz), fp) ==
        static_cast<size_t>(sz)) {
      const int off = stbtt_GetFontOffsetForIndex(f->data.data(), 0);
      if (off >= 0 && stbtt_InitFont(&f->info, f->data.data(), off))
        f->ok = true;
    }
  }
  std::fclose(fp);
  if (!f->ok) {
    const std::string msg = "[RGSS] failed to load font file: " + path;
    log_bridge_write_stderr(msg.c_str());
  }
  return f;
}

// First font file under the GAME_DIR/RTP_DIR `Fonts/` folders. With a `name`
// given, prefer an exact (lenient) family match, then a partial one, else the
// first font file found. Returns "" when no font file exists.
std::string find_font_path(mrb_state* M, const std::string& name) {
  const std::string roots[] = {object_const_str(M, "GAME_DIR"),
                               object_const_str(M, "RTP_DIR")};
  const std::string want = font_key(name);
  std::string first_any, partial;
  for (const std::string& root : roots) {
    if (root.empty())
      continue;
    const std::string dir = root + "/Fonts";
    DIR* d = opendir(dir.c_str());
    if (!d)
      continue;
    while (dirent* e = readdir(d)) {
      const std::string fn = e->d_name;
      if (!has_font_ext(fn))
        continue;
      const std::string full = dir + "/" + fn;
      if (first_any.empty())
        first_any = full;
      if (want.empty())
        continue;
      const std::string stem = font_key(fn.substr(0, fn.size() - 4));
      if (stem == want) {
        closedir(d);
        return full;
      }
      if (partial.empty() && stem.find(want) != std::string::npos)
        partial = full;
    }
    closedir(d);
  }
  return partial.empty() ? first_any : partial;
}
#endif  // !defined(WIO_TERMINAL)

// RGSS::Font.default_path, or "" when unset: the font to use for a project that
// ships none of its own. Opt-in per maker rather than automatic, because
// "wrong" differs by maker — RPG Maker XP/VX projects want a real TrueType face
// at the size they asked for (their boot points this at the bundled default
// font, see assets/fonts/README.md), while RPG2000 wants the shinonome bitmap
// font, whose metrics match RPG_RT's MS Gothic and which the render-parity
// comparisons are checked against. RPG2000 therefore leaves this nil.
std::string font_default_path(mrb_state* M) {
  const V rgss_mod = mrb_obj_value(mrb_module_get_id(M, MRB_SYM(RGSS)));
  const mrb_sym font_sym = MRB_SYM(Font);
  // Font is defined in this gem's mrblib, which is always loaded alongside the
  // native half -- but text must draw, not raise, for an embedder that loaded
  // only the C side.
  if (!mrb_const_defined(M, rgss_mod, font_sym))
    return std::string();
  const V font = mrb_const_get(M, rgss_mod, font_sym);
  // Font.default_path is a class-level attr_accessor (mrblib/lib.rb).
  V v = mrb_iv_get(M, font, MRB_IVSYM(default_path));
  if (!mrb_string_p(v))
    return std::string();
  return std::string(RSTRING_PTR(v), RSTRING_LEN(v));
}

// Loaded fonts cached by requested family name (the search roots are fixed for
// a run). A cached entry may hold an unloaded font (ok == false), i.e. "no
// usable font for this name"; that negative result is cached too, so the
// Fonts/ directory is scanned only once per name.
//
// The fallback path is part of the key, not just the name: a game's scripts may
// set Font.default_path (or the boot may set it after the first text has been
// drawn), and the entry cached before that must not outlive it.
#if !defined(WIO_TERMINAL)
std::shared_ptr<TtfFont> ttf_for_name(mrb_state* M, const std::string& name) {
  static std::map<std::string, std::shared_ptr<TtfFont>> cache;
  const std::string fallback = font_default_path(M);
  const std::string key = name + '\n' + fallback;
  const auto it = cache.find(key);
  if (it != cache.end())
    return it->second;
  std::string path = find_font_path(M, name);
  // Nothing under the project's own Fonts/ — fall back to the shared default.
  if (path.empty())
    path = fallback;
  std::shared_ptr<TtfFont> f =
      path.empty() ? std::make_shared<TtfFont>() : load_ttf(path);
  cache[key] = f;
  return f;
}
#endif  // !defined(WIO_TERMINAL)

// The subset of RGSS::Font a draw needs, read once from the bitmap's @font.
struct FontAttr {
#if !defined(WIO_TERMINAL)
  std::shared_ptr<TtfFont> ttf;
#endif
  double size = 22;
  bool bold = false, italic = false, outline = true, shadow = false;
  uint8_t color[4] = {0, 0, 0, 255};      // r, g, b, a
  uint8_t out_color[4] = {0, 0, 0, 128};  // r, g, b, a
};

void color_rgba(mrb_state* M, V cv, uint8_t out[4]) {
  if (mrb_nil_p(cv))
    return;
  Color& c = DataType<Color>::get(M, cv);
  out[0] = static_cast<uint8_t>(c.red);
  out[1] = static_cast<uint8_t>(c.green);
  out[2] = static_cast<uint8_t>(c.blue);
  out[3] = static_cast<uint8_t>(c.alpha);
}

FontAttr read_font(mrb_state* M, V self) {
  FontAttr fa;
#if !defined(WIO_TERMINAL)
  std::string name;
#endif
  const V fv = mrb_iv_get(M, self, MRB_IVSYM(font));
  if (!mrb_nil_p(fv)) {
    // Font's attributes are read from their ivars (attr_accessor-backed): an
    // override of a reader is not consulted.
#if !defined(WIO_TERMINAL)
    V nv = mrb_iv_get(M, fv, MRB_IVSYM(name));
    if (mrb_string_p(nv)) {
      name.assign(RSTRING_PTR(nv), RSTRING_LEN(nv));
    } else if (mrb_array_p(nv) && ary_size(nv) > 0 &&
               mrb_string_p(mrb_ary_ref(M, nv, 0))) {
      // RGSS accepts an array of family names; use the first.
      const V n0 = mrb_ary_ref(M, nv, 0);
      name.assign(RSTRING_PTR(n0), RSTRING_LEN(n0));
    }
#endif
    V sv = mrb_iv_get(M, fv, MRB_IVSYM(size));
    if (mrb_fixnum_p(sv))
      fa.size = static_cast<double>(mrb_fixnum(sv));
    else if (rgss::num_p(sv))
      fa.size = rgss::num_arg(M, sv);
    V bv = mrb_iv_get(M, fv, MRB_IVSYM(bold));
    fa.bold = mrb_bool(bv);
    V iv = mrb_iv_get(M, fv, MRB_IVSYM(italic));
    fa.italic = mrb_bool(iv);
    V ov = mrb_iv_get(M, fv, MRB_IVSYM(outline));
    fa.outline = mrb_bool(ov);
    V shv = mrb_iv_get(M, fv, MRB_IVSYM(shadow));
    fa.shadow = mrb_bool(shv);
    V cv = mrb_iv_get(M, fv, MRB_IVSYM(color));
    color_rgba(M, cv, fa.color);
    V ocv = mrb_iv_get(M, fv, MRB_IVSYM(out_color));
    color_rgba(M, ocv, fa.out_color);
  }
#if defined(WIO_TERMINAL)
  // A default face asks for the renderer this build left out; drawing it in
  // shinonome instead would hide that.
  if (!font_default_path(M).empty())
    mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(NotImplementedError)),
              "RGSS::Font.default_path: TrueType text is not compiled into "
              "the Wio Terminal build (ADR 0220)");
#else
  fa.ttf = ttf_for_name(M, name);
#endif
  return fa;
}

#if !defined(WIO_TERMINAL)
// Advance width and line height of `s` at `px` em size, in whole pixels.
void measure_text_ttf(TtfFont& f,
                      std::string_view s,
                      double px,
                      int& width,
                      int& height) {
  const float scale =
      stbtt_ScaleForMappingEmToPixels(&f.info, static_cast<float>(px));
  int asc = 0, desc = 0, gap = 0;
  stbtt_GetFontVMetrics(&f.info, &asc, &desc, &gap);
  double w = 0;
  int prev = 0;
  for (const char32_t c : s | una::views::utf8) {
    int adv = 0, lsb = 0;
    stbtt_GetCodepointHMetrics(&f.info, static_cast<int>(c), &adv, &lsb);
    if (prev)
      w += scale *
           stbtt_GetCodepointKernAdvance(&f.info, prev, static_cast<int>(c));
    w += scale * adv;
    prev = static_cast<int>(c);
  }
  width = static_cast<int>(::lround(w));
  height = static_cast<int>(::lround(scale * (asc - desc)));
}

// Blend a glyph coverage bitmap (`cov`, gw x gh, 8-bit alpha) into `bmp` in
// colour (r,g,b) scaled by `a`. `ox,oy` is the coverage's top-left device
// position. `dilate` > 0 spreads the coverage by that radius (a max filter) to
// paint an outline. `slant` shears each row horizontally about `baseline_y` for
// a synthetic italic.
void blit_glyph_cov(Bitmap& bmp,
                    const uint8_t* cov,
                    int gw,
                    int gh,
                    int ox,
                    int oy,
                    int baseline_y,
                    int r,
                    int g,
                    int b,
                    int a,
                    int dilate,
                    double slant) {
  for (int j = -dilate; j < gh + dilate; ++j) {
    const int ty = oy + j;
    if (ty < 0 || ty >= bmp.height)
      continue;
    const int shear =
        slant != 0.0 ? static_cast<int>(::lround(slant * (baseline_y - ty)))
                     : 0;
    for (int i = -dilate; i < gw + dilate; ++i) {
      int m = 0;
      if (dilate <= 0) {
        m = cov[j * gw + i];
      } else {
        for (int dy = -dilate; dy <= dilate && m < 255; ++dy) {
          const int sy = j + dy;
          if (sy < 0 || sy >= gh)
            continue;
          for (int dx = -dilate; dx <= dilate; ++dx) {
            const int sx = i + dx;
            if (sx < 0 || sx >= gw)
              continue;
            if (cov[sy * gw + sx] > m)
              m = cov[sy * gw + sx];
          }
        }
      }
      if (m <= 0)
        continue;
      const int tx = ox + i + shear;
      if (tx < 0 || tx >= bmp.width)
        continue;
      const int alpha = a * m / 255;
      if (alpha <= 0)
        continue;
      int dr, dg, db, da;
      bmp_read(bmp, tx, ty, dr, dg, db, da);
      const int inv = 255 - alpha;
      bmp_put(bmp, tx, ty, (r * alpha + dr * inv) / 255,
              (g * alpha + dg * inv) / 255, (b * alpha + db * inv) / 255,
              std::max(da, alpha));
    }
  }
}

// Like blit_glyph_cov, but instead of a flat colour the glyph is filled from a
// source region (`src` rect sx,sy,sw,sh) — the System windowskin's text-colour
// swatch — so the swatch's own shading blends into the text (RPG2000 draws its
// message text this way). The fill colour for a device row `ty` is sampled from
// the swatch column centre at the row mapped by the glyph's vertical position
// within the text line [tline_top, tline_top+tline_h], so a vertically-shaded
// swatch reads as a top-to-bottom gradient on the glyphs.
void blit_glyph_tex(Bitmap& bmp,
                    const uint8_t* cov,
                    int gw,
                    int gh,
                    int ox,
                    int oy,
                    int baseline_y,
                    double slant,
                    const Bitmap& src,
                    int sx,
                    int sy,
                    int sw,
                    int sh,
                    double tline_top,
                    double tline_h) {
  const int scol = sx + sw / 2;
  for (int j = 0; j < gh; ++j) {
    const int ty = oy + j;
    if (ty < 0 || ty >= bmp.height)
      continue;
    const int shear =
        slant != 0.0 ? static_cast<int>(::lround(slant * (baseline_y - ty)))
                     : 0;
    int srow = sy;
    if (sh > 1 && tline_h > 0.0) {
      int r = static_cast<int>(
          ::lround((static_cast<double>(ty) - tline_top) * (sh - 1) / tline_h));
      srow = sy + std::clamp(r, 0, sh - 1);
    }
    int sr = 255, sg = 255, sb = 255, sa = 255;
    if (scol >= 0 && srow >= 0 && scol < src.width && srow < src.height)
      bmp_read(src, scol, srow, sr, sg, sb, sa);
    for (int i = 0; i < gw; ++i) {
      const int m = cov[j * gw + i];
      if (m <= 0)
        continue;
      const int tx = ox + i + shear;
      if (tx < 0 || tx >= bmp.width)
        continue;
      const int alpha = m * sa / 255;
      if (alpha <= 0)
        continue;
      int dr, dg, db, da;
      bmp_read(bmp, tx, ty, dr, dg, db, da);
      const int inv = 255 - alpha;
      bmp_put(bmp, tx, ty, (sr * alpha + dr * inv) / 255,
              (sg * alpha + dg * inv) / 255, (sb * alpha + db * inv) / 255,
              std::max(da, alpha));
    }
  }
}

// Draw `s` into `bmp` with a TrueType font, laid out in the rect (x,y,w,h) with
// horizontal `align` (0 left, 1 centre, 2 right) and vertically centred. Shadow
// and outline (from the font's out_color) are painted under the fill; bold is a
// second fill offset one pixel; italic shears the glyphs.
void draw_text_ttf(Bitmap& bmp,
                   const FontAttr& fa,
                   TtfFont& f,
                   std::string_view s,
                   mrb_int x,
                   mrb_int y,
                   mrb_int w,
                   mrb_int h,
                   int align) {
  const float scale =
      stbtt_ScaleForMappingEmToPixels(&f.info, static_cast<float>(fa.size));
  int asc = 0, desc = 0, gap = 0;
  stbtt_GetFontVMetrics(&f.info, &asc, &desc, &gap);

  int tw = 0, th = 0;
  measure_text_ttf(f, s, fa.size, tw, th);
  if (align == 1)
    x += (w - tw) / 2;
  else if (align == 2)
    x += w - tw;

  // Baseline of a block vertically centred within the rect.
  const double top = y + (h - scale * (asc - desc)) / 2.0;
  const double baseY = top + scale * asc;

  const double slant = fa.italic ? 0.25 : 0.0;
  const bool do_outline = fa.outline && fa.out_color[3] > 0;

  double penX = static_cast<double>(x);
  int prev = 0;
  for (const char32_t c : s | una::views::utf8) {
    if (prev)
      penX += scale *
              stbtt_GetCodepointKernAdvance(&f.info, prev, static_cast<int>(c));
    int gw = 0, gh = 0, gx = 0, gy = 0;
    uint8_t* g = stbtt_GetCodepointBitmap(
        &f.info, scale, scale, static_cast<int>(c), &gw, &gh, &gx, &gy);
    if (g) {
      const int by = static_cast<int>(::lround(baseY));
      const int ox = static_cast<int>(::lround(penX)) + gx;
      const int oy = by + gy;
      if (fa.shadow)
        blit_glyph_cov(bmp, g, gw, gh, ox + 1, oy + 1, by, fa.out_color[0],
                       fa.out_color[1], fa.out_color[2], fa.out_color[3], 0,
                       slant);
      if (do_outline)
        blit_glyph_cov(bmp, g, gw, gh, ox, oy, by, fa.out_color[0],
                       fa.out_color[1], fa.out_color[2], fa.out_color[3], 1,
                       slant);
      blit_glyph_cov(bmp, g, gw, gh, ox, oy, by, fa.color[0], fa.color[1],
                     fa.color[2], fa.color[3], 0, slant);
      if (fa.bold)
        blit_glyph_cov(bmp, g, gw, gh, ox + 1, oy, by, fa.color[0], fa.color[1],
                       fa.color[2], fa.color[3], 0, slant);
      stbtt_FreeBitmap(g, nullptr);
    }
    int adv = 0, lsb = 0;
    stbtt_GetCodepointHMetrics(&f.info, static_cast<int>(c), &adv, &lsb);
    penX += scale * adv;
    prev = static_cast<int>(c);
  }
  bmp.dirty = true;
}

// Like draw_text_ttf, but the glyph fill is textured from a source swatch
// region (see blit_glyph_tex) rather than a flat colour. Shadow and outline
// stay the font's flat out_colour; only the main (and bold) fill is textured.
void draw_text_tex_ttf(Bitmap& bmp,
                       const FontAttr& fa,
                       TtfFont& f,
                       std::string_view s,
                       mrb_int x,
                       mrb_int y,
                       mrb_int w,
                       mrb_int h,
                       int align,
                       const Bitmap& src,
                       int sx,
                       int sy,
                       int sw,
                       int sh) {
  const float scale =
      stbtt_ScaleForMappingEmToPixels(&f.info, static_cast<float>(fa.size));
  int asc = 0, desc = 0, gap = 0;
  stbtt_GetFontVMetrics(&f.info, &asc, &desc, &gap);

  int tw = 0, th = 0;
  measure_text_ttf(f, s, fa.size, tw, th);
  if (align == 1)
    x += (w - tw) / 2;
  else if (align == 2)
    x += w - tw;

  const double top = y + (h - scale * (asc - desc)) / 2.0;
  const double baseY = top + scale * asc;
  const double tline_h = scale * (asc - desc);
  const double slant = fa.italic ? 0.25 : 0.0;
  const bool do_outline = fa.outline && fa.out_color[3] > 0;

  double penX = static_cast<double>(x);
  int prev = 0;
  for (const char32_t c : s | una::views::utf8) {
    if (prev)
      penX += scale *
              stbtt_GetCodepointKernAdvance(&f.info, prev, static_cast<int>(c));
    int gw = 0, gh = 0, gx = 0, gy = 0;
    uint8_t* g = stbtt_GetCodepointBitmap(
        &f.info, scale, scale, static_cast<int>(c), &gw, &gh, &gx, &gy);
    if (g) {
      const int by = static_cast<int>(::lround(baseY));
      const int ox = static_cast<int>(::lround(penX)) + gx;
      const int oy = by + gy;
      if (fa.shadow)
        blit_glyph_cov(bmp, g, gw, gh, ox + 1, oy + 1, by, fa.out_color[0],
                       fa.out_color[1], fa.out_color[2], fa.out_color[3], 0,
                       slant);
      if (do_outline)
        blit_glyph_cov(bmp, g, gw, gh, ox, oy, by, fa.out_color[0],
                       fa.out_color[1], fa.out_color[2], fa.out_color[3], 1,
                       slant);
      blit_glyph_tex(bmp, g, gw, gh, ox, oy, by, slant, src, sx, sy, sw, sh,
                     top, tline_h);
      if (fa.bold)
        blit_glyph_tex(bmp, g, gw, gh, ox + 1, oy, by, slant, src, sx, sy, sw,
                       sh, top, tline_h);
      stbtt_FreeBitmap(g, nullptr);
    }
    int adv = 0, lsb = 0;
    stbtt_GetCodepointHMetrics(&f.info, static_cast<int>(c), &adv, &lsb);
    penX += scale * adv;
    prev = static_cast<int>(c);
  }
  bmp.dirty = true;
}

#endif  // !defined(WIO_TERMINAL)

// Measure the pixel width and height of `s` using the shinonome font tables.
void measure_text(std::string_view s, int& width, unsigned& height) {
  width = 0;
  height = 0;
  for (const char32_t c : s | una::views::utf8) {
    auto f = find_gothic_char(c);
    if (f) {
      width += f->WIDTH;
      height = std::max<unsigned>(height, f->HEIGHT);
      continue;
    }
    auto h = find_char(c, shinonome::LATIN1, shinonome::LATIN1_LEN);
    if (h) {
      width += h->WIDTH;
      height = std::max<unsigned>(height, h->HEIGHT);
      continue;
    }
    h = find_char(c, shinonome::HANKAKU, shinonome::HANKAKU_LEN);
    if (h) {
      width += h->WIDTH;
      height = std::max<unsigned>(height, h->HEIGHT);
      continue;
    }
  }
}

// Top row of the shinonome glyph cell for a text run laid out in a rect of
// height `h`: RGSS centres a line of text in the rect it is given, which the
// TrueType path above already does with the face's own ascent/descent. The
// shinonome cells are a fixed `shinonome::HEIGHT` (12) tall, so the bitmap
// path centres that cell the same way instead of pinning it to the rect's
// top -- a 16px line, RPG2000's own, puts the glyph cell 2px below the line's
// top.
//
// Measured on genuine RPG_RT.exe under wine (Nepheshel, 640x480 captures
// halved to the 320x240 logical screen, cycle #248): in the field menu the
// command row `装備` inks screen rows 43..52 and the party panel's `デモ用`
// 12..21, both symmetric inside the 12px cell this puts at 42..53 and 10..21;
// the same strings in the load screen (`デモ用` at 68..77) and the battle
// status panel (171..181) sit on the same relation only once the cell is
// centred -- top-aligning it drew them 2px high (our 65..76 and 168..180).
mrb_int shinonome_text_top(mrb_int y, mrb_int h) {
  return y + (h - static_cast<mrb_int>(shinonome::HEIGHT)) / 2;
}

// Every pixel the shinonome glyphs of `sv` set when laid out from (x, y), as
// put(px, py).
template <class Put>
void shinonome_pixels(std::string_view sv, mrb_int x, mrb_int y, Put&& put) {
  auto draw = [&x, y, &put](const auto& c) {
    for (unsigned i = 0; i < c.HEIGHT; ++i) {
      for (unsigned j = 0; j < c.WIDTH; ++j) {
        const unsigned idx = i * c.WIDTH + j;
        if (c.data[idx / 32] & (1 << (idx % 32)))
          put(x + j, y + i);
      }
    }
    x += c.WIDTH;
  };
  for (const char32_t c : sv | una::views::utf8) {
    auto f = find_gothic_char(c);
    if (f) {
      draw(*f);
      continue;
    }
    auto hh = find_char(c, shinonome::LATIN1, shinonome::LATIN1_LEN);
    if (hh) {
      draw(*hh);
      continue;
    }
    hh = find_char(c, shinonome::HANKAKU, shinonome::HANKAKU_LEN);
    if (hh) {
      draw(*hh);
      continue;
    }
  }
}

// The text run `sv`, `tw` pixels wide with its glyph cell's top-left at
// (x, y), as an op over its part inside `b` and the glyph pixels there; false
// when none of it is inside.
static bool text_layout(const Bitmap& b,
                        std::string_view sv,
                        mrb_int x,
                        mrb_int y,
                        int tw,
                        DeferredOp& o,
                        DeferredText& t) {
  const mrb_int x0 = std::max<mrb_int>(x, 0), y0 = std::max<mrb_int>(y, 0);
  const mrb_int x1 = std::min<mrb_int>(x + tw, b.width);
  const mrb_int y1 =
      std::min<mrb_int>(y + static_cast<mrb_int>(shinonome::HEIGHT), b.height);
  if (x0 >= x1 || y0 >= y1)
    return false;
  o = DeferredOp{static_cast<int16_t>(x0),
                 static_cast<int16_t>(y0),
                 0,
                 0,
                 static_cast<uint16_t>(x1 - x0),
                 static_cast<uint16_t>(y1 - y0),
                 0,
                 255,
                 kDeferredText};
  const size_t stride = (o.w + 7) / 8;
  t.top = static_cast<int16_t>(y);
  t.mask.assign(stride * o.h, 0);
  shinonome_pixels(sv, x, y, [&](mrb_int px, mrb_int py) {
    if (px < x0 || py < y0 || px >= x1 || py >= y1)
      return;
    const size_t i = static_cast<size_t>(px - x0);
    t.mask[static_cast<size_t>(py - y0) * stride + i / 8] |=
        static_cast<uint8_t>(1u << (i % 8));
  });
  return true;
}

// Store a text run's rows [a, e) of the bitmap into `win`, which holds its
// rows from y0.
static void text_stamp(Bitmap& win,
                       int y0,
                       const DeferredOp& o,
                       const DeferredText& t,
                       int a,
                       int e) {
  const unsigned bpp = pixel_size(win.format);
  const size_t stride = (o.w + 7) / 8;
  for (int py = a; py < e; ++py) {
    const uint8_t* m = t.mask.data() + static_cast<size_t>(py - o.dy) * stride;
    const uint8_t* c = t.rows.data() + static_cast<size_t>(py - t.top) * 4;
    uint8_t* d = win.buffer.data() +
                 (static_cast<size_t>(py - y0) * win.width + o.dx) * bpp;
    for (int i = 0; i < o.w; ++i)
      if (m[i / 8] & (1u << (i % 8)))
        std::memcpy(d + static_cast<size_t>(i) * bpp, c, bpp);
  }
}

// Draw (or, into a deferred `b`, record) the text run `sv`, `tw` pixels wide,
// its glyph cell's top-left at (x, y), each cell row i storing rows[i * 4..].
static void text_draw(Bitmap& b,
                      std::string_view sv,
                      mrb_int x,
                      mrb_int y,
                      int tw,
                      const std::array<uint8_t, shinonome::HEIGHT * 4>& rows) {
  DeferredOp o;
  DeferredText t;
  if (!text_layout(b, sv, x, y, tw, o, t))
    return;
  if (!b.deferred)
    promote_to_direct(b);
  t.rows = rows;
  if (!b.deferred) {
    text_stamp(b, 0, o, t, o.dy, o.dy + o.h);
    return;
  }
  DeferredList& L = deferred_edit(b);
  L.texts.push_back(std::move(t));
  o.sx = static_cast<uint16_t>(L.texts.size() - 1);
  deferred_push(b, o, false);
}

mrb_value bmp_draw_text_body(mrb_state* M,
                             mrb_value self,
                             mrb_int x,
                             mrb_int y,
                             mrb_int w,
                             mrb_int h,
                             mrb_value text_obj,
                             mrb_int align);

// RGSS Bitmap#draw_text, in both the forms RGSS documents:
//
//   draw_text(x, y, width, height, str[, align])
//   draw_text(rect, str[, align])
//
// The Rect form is not a nicety -- `Window_Command#draw_item`, the menu every
// game's title screen is built from, calls it -- so a bitmap that only took the
// four-number form stopped a game's own engine at its first window with
// "wrong number of arguments (given 2, expected 5..6)". Same argc branch as
// #fill_rect, which RGSS overloads the same way.
mrb_value bmp_draw_text(mrb_state* M, mrb_value self) {
  // Real RGSS3 accepts any object as the text argument, not just a String --
  // games routinely draw_text an Integer directly (HP/MP/gold: this game's
  // own stock Window_Gold#refresh -> #draw_currency_value among them),
  // relying on the same implicit #to_s Ruby's own String() gives it. Parsed
  // as a generic object ("o") rather than mrb_get_args' own "s" (which
  // demands an actual String) and coerced after: mrb_obj_as_string can run
  // arbitrary Ruby (#to_s) and possibly grow the VM's value stack, which
  // would leave a raw argv pointer obtained before it dangling -- calling
  // mrb_get_args a second time to re-parse against such a pointer read
  // freed memory. One parse, then a local mrb_value, sidesteps that.
  mrb_int x, y, w, h;
  mrb_int align = 0;
  mrb_value text_obj;
  if (mrb_get_argc(M) <= 3) {
    V r;
    mrb_get_args(M, "oo|i", &r, &text_obj, &align);
    Rect& rc = DataType<Rect>::get(M, r);
    x = rc.x;
    y = rc.y;
    w = rc.width;
    h = rc.height;
  } else {
    mrb_get_args(M, "iiiio|i", &x, &y, &w, &h, &text_obj, &align);
  }
  return bmp_draw_text_body(M, self, x, y, w, h, text_obj, align);
}

mrb_value bmp_draw_text_body(mrb_state* M,
                             mrb_value self,
                             mrb_int x,
                             mrb_int y,
                             mrb_int w,
                             mrb_int h,
                             mrb_value text_obj,
                             mrb_int align) {
  // Not materialized: a deferred bitmap records the run (see text_draw).
  Bitmap& bmp = bmp_raw(M, self);
  if (!mrb_string_p(text_obj)) {
    text_obj = mrb_obj_as_string(M, text_obj);
  }
  const std::string_view sv(RSTRING_PTR(text_obj), RSTRING_LEN(text_obj));

  // Prefer the game's TrueType font (RPG Maker XP/VX ship one under Fonts/),
  // rasterising at the font's pixel size. Fall back to the fixed-size shinonome
  // bitmap font when no usable font file is found.
  const FontAttr fa = read_font(M, self);
#if !defined(WIO_TERMINAL)
  if (fa.ttf && fa.ttf->ok) {
    settle_for_access(bmp);
    promote_to_direct(bmp);
    draw_text_ttf(bmp, fa, *fa.ttf, sv, x, y, w, h, static_cast<int>(align));
    return self;
  }
#endif

  // Text colour comes from the font (default opaque black when no @font is
  // set), laid out in the bitmap's byte order (B, G, R, A).
  const uint8_t col[4] = {fa.color[2], fa.color[1], fa.color[0], fa.color[3]};

  // Horizontal alignment: 0 left, 1 center, 2 right.
  int tw = 0;
  unsigned th = 0;
  measure_text(sv, tw, th);
  if (align == 1)
    x += (w - tw) / 2;
  else if (align == 2)
    x += w - tw;
  y = shinonome_text_top(y, h);

  std::array<uint8_t, shinonome::HEIGHT * 4> rows;
  for (unsigned i = 0; i < shinonome::HEIGHT; ++i)
    std::memcpy(rows.data() + i * 4, col, 4);
  text_draw(bmp, sv, x, y, tw, rows);

  bmp.dirty = true;
  return self;
}

// Draw text whose glyphs are filled from a source region of `src` (a System
// windowskin's text-colour swatch) instead of a flat colour, so the swatch's
// shading blends into the text — RPG2000's message-colour rendering. Same
// layout as draw_text; args: (x, y, w, h, text, src, sx, sy, sw, sh[, align]).
// Uses the TrueType path when a game font is present, else the shinonome bitmap
// font (what RPG2000 games use), sampling the swatch by vertical position for a
// top-to-bottom gradient.
mrb_value bmp_blend_text(mrb_state* M, mrb_value self) {
  // Not materialized: a deferred bitmap records the run (see text_draw).
  auto& bmp = bmp_raw(M, self);

  mrb_int x, y, w, h, len, sx, sy, sw, sh;
  mrb_int align = 0;
  const char* s;
  void* src;
  mrb_get_args(M, "iiiisdiiii|i", &x, &y, &w, &h, &s, &len, &src,
               &DataType<Bitmap>::data_type, &sx, &sy, &sw, &sh, &align);
  Bitmap& src_bmp = bmp_require(M, src);
  const std::string_view sv(s, len);

  [[maybe_unused]] const FontAttr fa = read_font(M, self);
#if !defined(WIO_TERMINAL)
  if (fa.ttf && fa.ttf->ok) {
    settle_for_access(bmp);
    draw_text_tex_ttf(bmp, fa, *fa.ttf, sv, x, y, w, h, static_cast<int>(align),
                      src_bmp, static_cast<int>(sx), static_cast<int>(sy),
                      static_cast<int>(sw), static_cast<int>(sh));
    return self;
  }
#endif

  int tw = 0;
  unsigned th = 0;
  measure_text(sv, tw, th);
  if (align == 1)
    x += (w - tw) / 2;
  else if (align == 2)
    x += w - tw;
  y = shinonome_text_top(y, h);

  // Each glyph row's colour: the swatch row its height maps to, so a shaded
  // swatch gradients down the text; a flat swatch reads as a single colour.
  const int scol = static_cast<int>(sx + sw / 2);
  constexpr unsigned kCell = shinonome::HEIGHT;
  std::array<uint8_t, kCell * 4> rows;
  for (unsigned i = 0; i < kCell; ++i) {
    int srow = static_cast<int>(sy);
    if (sh > 1 && kCell > 1)
      srow = static_cast<int>(sy) +
             std::clamp(static_cast<int>(::lround(static_cast<double>(i) *
                                                  (sh - 1) / (kCell - 1))),
                        0, static_cast<int>(sh) - 1);
    int sr = 255, sg = 255, sb = 255, sa = 255;
    if (scol >= 0 && srow >= 0 && scol < src_bmp.width && srow < src_bmp.height)
      bmp_read(src_bmp, scol, srow, sr, sg, sb, sa);
    // bmp_put's byte order.
    rows[i * 4] = static_cast<uint8_t>(sb);
    rows[i * 4 + 1] = static_cast<uint8_t>(sg);
    rows[i * 4 + 2] = static_cast<uint8_t>(sr);
    rows[i * 4 + 3] = static_cast<uint8_t>(sa);
  }
  text_draw(bmp, sv, x, y, tw, rows);

  bmp.dirty = true;
  return self;
}

mrb_value bmp_text_size_body(mrb_state* M,
                             mrb_value self,
                             const char* s,
                             mrb_int len) {
  const std::string_view sv(s, len);

  int w = 0;
  int height = 0;
  [[maybe_unused]] const FontAttr fa = read_font(M, self);
#if !defined(WIO_TERMINAL)
  if (fa.ttf && fa.ttf->ok) {
    measure_text_ttf(*fa.ttf, sv, fa.size, w, height);
  } else
#endif
  {
    unsigned uh = 0;
    measure_text(sv, w, uh);
    height = static_cast<int>(uh);
  }

  const mrb_value args[] = {
      mrb_fixnum_value(0),
      mrb_fixnum_value(0),
      mrb_fixnum_value(w),
      mrb_fixnum_value(height),
  };

  return mrb_obj_new(M,
                     mrb_class_get_under_id(
                         M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Rect)),
                     4, args);
}

mrb_value bmp_text_size_native_body(mrb_state* M,
                                    mrb_value self,
                                    const char* s,
                                    mrb_int len) {
  return bmp_text_size_body(M, self, s, len);
}

mrb_value bmp_text_size(mrb_state* M, mrb_value self) {
  mrb_int len;
  const char* s;
  mrb_get_args(M, "s", &s, &len);
  return bmp_text_size_native_body(M, self, s, len);
}

// DISPLAY_IVARS: the RData payload of a display object (Sprite, Viewport,
// Plane, Tilemap and its strips, Window): its backend node, then a slot for
// each ivar its mrb_data_type names. mrb_iv_get/mrb_iv_set find those in the
// payload by name (rdata_ivar_find, 3rd/mruby/src/variable.c), so an object
// that sets no other ivar keeps no iv_tbl. A slot costs every object and a
// table only the objects that set an ivar without one, so the slots are the
// ivars nearly every object sets. #dispose clears `node` only: the ivars
// outlive it, as before.
struct DisplayHead {
  gfx::Node* node;
  // mrb_iv_copy (#dup, #clone) copies the payload byte for byte, node and all;
  // a copy is not its own `self`, so it owns no node.
  const DisplayHead* self;
};

template <size_t N>
struct DisplayObj {
  DisplayHead head;
  mrb_value iv[N];
};

void free_display(mrb_state* M, void* p);

bool display_p(mrb_value v) {
  return DATA_TYPE(v) && DATA_TYPE(v)->dfree == free_display;
}

// The node of a display object; null once it is disposed.
gfx::Node* display_node(mrb_value v) {
  const DisplayHead* h = static_cast<const DisplayHead*>(DATA_PTR(v));
  return h && h->self == h ? h->node : nullptr;
}

// RGSS #disposed?: whether #dispose has already run. It clears the data pointer
// (a display object's node, see DISPLAY_IVARS), so a null one *is* the
// disposed state -- this used to answer the other way round, reporting every
// live object as disposed and every disposed one as live. The stock scripts
// guard cleanup and redraws with it (`unless bitmap.disposed?`), so inverted it
// meant skipping work on a live object and touching a freed one.
mrb_value obj_disposed(mrb_state* M, mrb_value self) {
  if (display_p(self))
    return mrb_bool_value(!display_node(self));
  return mrb_bool_value(DATA_PTR(self) == nullptr);
}

mrb_value obj_dispose(mrb_state* M, mrb_value self) {
  if (display_p(self)) {
    if (gfx::Node* n = display_node(self)) {
      gfx::node_delete(n);
      static_cast<DisplayHead*>(DATA_PTR(self))->node = nullptr;
    }
    return mrb_nil_value();
  }
  if (!DATA_PTR(self))
    return mrb_nil_value();

  DATA_TYPE(self)->dfree(M, DATA_PTR(self));
  DATA_PTR(self) = nullptr;
  return mrb_nil_value();
}

// Array of z-ordered display objects (Sprites and Viewports). Stacking is
// resolved per LVGL parent: sprites sharing a parent (the screen, or a
// Viewport's content layer) are ordered among themselves by their `z`.
// Populated by register_zobj.
mrb_value zorder_objs(mrb_state* M) {
  const mrb_value mod = mrb_obj_value(mrb_module_get_id(M, MRB_SYM(RGSS)));
  const mrb_value ret = mrb_const_get(M, mod, MRB_SYM(_zobjs));
  mrb_assert(mrb_array_p(ret));
  return ret;
}

// Flag the module so the next Graphics.update reshuffles LVGL sibling order to
// match the objects' `z` values. Reordering every frame would be wasteful, so
// callers only mark it dirty when a `z` (or the root set) actually changes.
void update_z(mrb_state* M) {
  const mrb_value mod = mrb_obj_value(mrb_module_get_id(M, MRB_SYM(RGSS)));
  mrb_iv_set(M, mod, MRB_SYM(_z_updated), mrb_true_value());
}

// Drain every backend's buffered key transitions into RGSS::Input. Called from
// Input.update (mrblib/lib.rb) — *not* from Graphics.update, which is where
// this used to live and where it silently broke every game that runs its own
// engine: an RGSS scene loop is
//
//   loop { Graphics.update; Input.update; update; break if $scene != self }
//
// so transitions applied during Graphics.update were wiped by the game's own
// Input.update (which expires the previous frame's triggers) before the scene
// read them — `Input.trigger?` could never be true under the script host, and
// no game could be played. RGSS's contract is that Input.update is what
// refreshes input, so that is where the drain belongs; the built-in flows call
// it once a frame too, so their timing is unchanged.
mrb_value input_poll(mrb_state* M, mrb_value self) {
  rgss_terminal_poll(M);
  rgss_sdl_poll(M);
#if defined(WIO_TERMINAL)
  rgss_wio_poll(M);
#endif
#if defined(PSP_BUILD)
  rgss_psp_poll(M);
#endif
#if defined(MAIX_BUILD)
  rgss_maix_poll(M);
#endif
  return mrb_nil_value();
}

// Push a key transition into the same buffer the SDL backend feeds, from Ruby.
// The headless tests use it to drive the loop above without a window.
mrb_value input_push_native_body(mrb_state* M,
                                 mrb_value self,
                                 mrb_int key,
                                 mrb_bool press) {
  rgss_sdl_input_push(static_cast<int>(key), press);
  return mrb_nil_value();
}

mrb_value input_push(mrb_state* M, mrb_value self) {
  mrb_int key;
  mrb_bool press;
  mrb_get_args(M, "ib", &key, &press);
  return input_push_native_body(M, self, key, press);
}

// Frame pacing state, shared with Graphics.frame_reset below. See the long note
// in gfx_update for why the deadline is absolute rather than "sleep whatever is
// left of a frame".
uint32_t g_next_frame = 0;
uint32_t g_period_acc = 0;
bool g_paced = false;

// --render_fps (src/main.cxx): duty-cycle accumulator deciding which of every
// 60 Graphics.update calls actually reach the LVGL redraw below (same
// Bresenham-style technique as g_period_acc above, just spreading renders
// instead of milliseconds evenly across the 60 calls-per-second baseline).
uint32_t g_render_acc = 0;

// RGSS Graphics.frame_reset: "resets the screen refresh timing", called after
// something slow so the game does not then run fast catching up. The pacing
// below carries an absolute deadline forward, so after a long stall it owes a
// burst of short frames -- the very thing a game calls this to avoid. It does
// re-base itself once it is more than a frame behind, which is why a game could
// get away without this, but only after spending that frame: `Scene_Map#
// transfer_player` and every map build call frame_reset precisely so the frame
// they were on is not the one that pays.
//
// Dropping the deadline is the whole implementation: the next update sees
// !g_paced and starts counting from then.
#if !defined(WIO_TERMINAL)  // dead weight on wio: no Ruby path reaches it
mrb_value gfx_frame_reset(mrb_state* M, mrb_value self) {
  (void)M;
  g_paced = false;
  return self;
}
#endif  // !defined(WIO_TERMINAL)

// Whether *this* Graphics.update call should reach the LVGL redraw, per
// --render_fps (src/main.cxx). Game logic runs every call regardless -- this
// only gates the z-reorder/bitmap-invalidate/LVGL draw work below, so a lower
// setting redraws the screen less often without changing how fast the game
// itself runs. Undefined (e.g. the per-gem `rake test` binary, which never
// runs main.cxx) means "render every frame", same fallback as NO_RENDER_WAIT.
bool render_due(mrb_state* M) {
  int32_t render_fps = 60;
  if (mrb_const_defined(M, mrb_obj_value(M->object_class),
                        MRB_SYM(RENDER_FPS))) {
    const mrb_value v =
        mrb_const_get(M, mrb_obj_value(M->object_class), MRB_SYM(RENDER_FPS));
    mrb_assert(mrb_fixnum_p(v));
    render_fps = static_cast<int32_t>(mrb_fixnum(v));
  }
  if (render_fps >= 60)
    return true;
  if (render_fps <= 0)
    return false;
  g_render_acc += static_cast<uint32_t>(render_fps);
  if (g_render_acc < 60)
    return false;
  g_render_acc -= 60;
  return true;
}

mrb_value gfx_update(mrb_state* M, mrb_value self) {
  const mrb_value rgss_mod = mrb_obj_value(mrb_module_get_id(M, MRB_SYM(RGSS)));

  rgss_audio_frame();

  if (mrb_const_defined(M, mrb_obj_value(M->object_class),
                        MRB_SYM(TIMEOUT_MS))) {
    const mrb_value timeout_ms =
        mrb_const_get(M, mrb_obj_value(M->object_class), MRB_SYM(TIMEOUT_MS));
    mrb_assert(mrb_fixnum_p(timeout_ms));
    const mrb_value start = mrb_const_get(M, rgss_mod, MRB_SYM(_game_start));
    mrb_assert(mrb_fixnum_p(start));

    if (mrb_fixnum(timeout_ms) > 0 &&
        (gfx::tick_ms() - mrb_fixnum(start)) > mrb_fixnum(timeout_ms)) {
      mrb_raisef(M,
                 mrb_class_get_under_id(M, mrb_module_get_id(M, MRB_SYM(RGSS)),
                                        MRB_SYM(Timeout)),
                 "Timeout");
    }
  }

  // --render_fps (src/main.cxx): on a skipped frame, leave the z/dirty flags
  // set rather than touching them, so the next frame that does render picks
  // up everything that changed while it waited -- no dropped update, just a
  // deferred repaint.
  if (render_due(M)) {
    // Reapply z ordering when something changed since the last frame. LVGL
    // draws siblings in child order, so within each LVGL parent we sort that
    // parent's z-managed objects by `z` and move them to the foreground from
    // lowest to highest, leaving the greatest `z` on top. Grouping by parent
    // means sprites that live inside a Viewport are ordered among
    // themselves, while the Viewport (and top-level sprites) are ordered
    // against each other on the screen. Disposed objects (no node) are
    // dropped from the set here so it does not grow unbounded.
    if (mrb_bool(mrb_iv_get(M, rgss_mod, MRB_SYM(_z_updated)))) {
      ProfilerScope _zscope("gfx.zorder");
      const mrb_value objs = zorder_objs(M);
      const mrb_value live = mrb_ary_new(M);
      std::map<gfx::Node*, std::multimap<mrb_int, gfx::Node*>> by_parent;
      for (mrb_int i = 0; i < ary_size(objs); ++i) {
        const mrb_value v = ary_items(objs)[i];
        if (!display_node(v))
          continue;
        mrb_ary_push(M, live, v);
        gfx::Node* obj = display_node(v);
        const mrb_value z = mrb_iv_get(M, v, MRB_IVSYM(z));
        mrb_assert(mrb_fixnum_p(z));
        by_parent[gfx::node_parent(obj)].insert({mrb_fixnum(z), obj});
      }
      mrb_const_set(M, rgss_mod, mrb_intern_lit(M, "_zobjs"), live);
      for (const auto& group : by_parent)
        for (const auto& order : group.second)
          gfx::node_raise(order.second);
      mrb_iv_set(M, rgss_mod, MRB_SYM(_z_updated), mrb_false_value());
    }

    // Bitmap mutators write straight into the shared pixel buffer, which LVGL
    // does not observe. Walk the live sprites and invalidate any whose bitmap
    // has been touched since the last frame so LVGL repaints them below.
    // Flags are cleared only after the whole sweep so a bitmap shared by
    // several sprites invalidates all of them.
    {
      ProfilerScope _iscope("gfx.invalidate");
      const mrb_value roots = zorder_objs(M);
      const mrb_sym bitmap_sym = MRB_IVSYM(bitmap);
      for (mrb_int i = 0; i < ary_size(roots); ++i) {
        const mrb_value v = ary_items(roots)[i];
        gfx::Node* obj = display_node(v);
        if (!obj)
          continue;
        const mrb_value bmpv = mrb_iv_get(M, v, bitmap_sym);
        if (mrb_nil_p(bmpv) || !DATA_PTR(bmpv))
          continue;
        // DATA_PTR(bmpv) is the shared_ptr<Bitmap> *box* DataType<Bitmap>
        // now stores (see DataType<T>'s own comment), not a Bitmap* --
        // already null-checked just above, so dereferencing through it
        // here (rather than the slightly heavier DataType<Bitmap>::get,
        // which re-does a type check this hot per-frame loop doesn't
        // need) is exactly the same access DataType<Bitmap>::get itself
        // does, just spelled out inline to match this file's own existing
        // direct-DATA_PTR style at this call site.
        Bitmap* b =
            reinterpret_cast<std::shared_ptr<Bitmap>*>(DATA_PTR(bmpv))->get();
        if (b->dirty)
          gfx::node_invalidate(obj);
      }
      // Second pass: clear the flags now that every referencing sprite is
      // marked.
      for (mrb_int i = 0; i < ary_size(roots); ++i) {
        const mrb_value v = ary_items(roots)[i];
        if (!display_node(v))
          continue;
        const mrb_value bmpv = mrb_iv_get(M, v, bitmap_sym);
        if (mrb_nil_p(bmpv) || !DATA_PTR(bmpv))
          continue;
        reinterpret_cast<std::shared_ptr<Bitmap>*>(DATA_PTR(bmpv))
            ->get()
            ->dirty = false;
      }
    }

    draw_headroom(M);
    {
      ProfilerScope _lvscope("gfx.lvgl");
      PixelGcHold hold;
      gfx::frame_draw();
    }
  }

  // Advance Graphics.frame_count, matching RGSS semantics.
  V gfx = mrb_obj_value(mrb_module_get_under_id(
      M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Graphics)));
  V fc = mrb_iv_get(M, gfx, MRB_IVSYM(frame_count));
  mrb_iv_set(M, gfx, MRB_IVSYM(frame_count),
             mrb_fixnum_value((mrb_fixnum_p(fc) ? mrb_fixnum(fc) : 0) + 1));

  // Frame pacing, against an absolute deadline rather than "sleep whatever is
  // left of 16ms". gfx::delay_ms overshoots by several milliseconds (it is a
  // usleep at OS timer granularity), and sleeping the remainder every frame
  // lets that overshoot accumulate: measured against a genuine RPG_RT under
  // wine, ~9ms of work per frame settled at 44fps instead of 60, so every timed
  // thing in the game -- walk cycles, animated tiles, message reveal, Wait
  // commands -- ran about a quarter too slow. Carrying the
  // deadline forward instead makes the next frame's sleep absorb the previous
  // one's overshoot. If we fall more than one frame behind (a slow map build,
  // a breakpoint), the deadline is re-based on now so we do not then spin
  // through a burst of catch-up frames -- that rebase is counted as a dropped
  // frame for RGSS::Profiler's stats (frame_reset's deliberate reset below is
  // not, since nothing was actually missed).
  //
  // A frame is 1000/60 ms, which is not an integer, so the deadline steps by
  // 17,17,16,... driven by a 1/60-ms remainder accumulator rather than a flat
  // 16 (which would run 4% fast).
  //
  // --no_render_wait (src/main.cxx) skips this whole block: it exists to make
  // a *played* game feel right (see above), which a headless smoke test never
  // watches. Every timer that block protects is driven off frame_count, not
  // the wall clock, so the frames that run are identical either way -- this
  // only removes the idle wait between them, which is most of a headless
  // run's wall-clock time (each frame's own work is a few ms; the wait pads
  // it to a full 1/60s regardless).
  if (!mrb_const_defined(M, mrb_obj_value(M->object_class),
                         MRB_SYM(NO_RENDER_WAIT)) ||
      !mrb_test(mrb_const_get(M, mrb_obj_value(M->object_class),
                              MRB_SYM(NO_RENDER_WAIT)))) {
    const uint32_t now = gfx::tick_ms();
    g_period_acc += 1000;
    const uint32_t period = g_period_acc / 60;
    g_period_acc %= 60;
    const bool overrun = g_paced && static_cast<int32_t>(now - g_next_frame) >
                                        static_cast<int32_t>(period);
    if (!g_paced || overrun) {
      if (overrun)
        profiler_note_frame_drop();
      g_next_frame = now;
      g_paced = true;
    }
    g_next_frame += period;
    const int32_t sleep = static_cast<int32_t>(g_next_frame - gfx::tick_ms());
    if (sleep > 0) {
      // Report the idle wait so the profiler can subtract it: the frame spans
      // the whole main_loop iteration (see RGSS::Profiler.frame), and we want
      // its "work" figure to measure CPU cost, not the time spent sleeping.
      profiler_note_idle(sleep);
#ifndef __EMSCRIPTEN__
      // Everywhere else this is a real OS sleep, so it costs nothing but wall
      // clock. Under Emscripten it would instead block the browser's single
      // JS thread synchronously -- the same thread that pumps the Web Audio
      // ScriptProcessorNode callback (there is no AUDIO_WORKLET/pthreads build
      // here, see docs/profiling.md), so a blocking wait here starves audio
      // and produces exactly the audible glitches/delay this was meant to
      // avoid. `emscripten_set_main_loop`'s own fps-throttled scheduling
      // (src/main.cxx) already paces calls non-blockingly, cooperating with
      // the browser's event loop instead of freezing it, so this deadline
      // math still runs (g_next_frame keeps carrying the remainder forward)
      // but the actual wait is left to the browser.
      gfx::delay_ms(sleep);
#endif
    }
  }

  return mrb_nil_value();
}

void free_display(mrb_state* M, void* p) {
  if (!p)
    return;
  DisplayHead* h = static_cast<DisplayHead*>(p);
  if (h->self == h && h->node)
    gfx::node_delete(h->node);
  mrb_free(M, p);
}

gfx::Display* get_display(mrb_state* M) {
  mrb_value v = mrb_const_get(
      M, mrb_obj_value(mrb_module_get_id(M, MRB_SYM(RGSS))), MRB_SYM(_display));
  mrb_assert(mrb_cptr_p(v));
  return reinterpret_cast<gfx::Display*>(mrb_cptr(v));
}

// Report an unimplemented path through RGSS.warn_stub, which dedupes by name.
void RGSS_warn_stub(mrb_state* M, const char* name) {
  mrb_funcall_id(M, mrb_obj_value(mrb_module_get_id(M, MRB_SYM(RGSS))),
                 MRB_SYM(warn_stub), 1, mrb_str_new_cstr(M, name));
}

// RGSS Graphics.snap_to_bitmap: the rendered screen as a Bitmap. The snapshot's
// rows are a Bitmap's ARGB8888 layout, so they copy straight across (honouring
// its stride, which is padded).
//
// Answers nil where the backend cannot capture (the Wio/PSP builds) rather than
// pretending, and says so once.
mrb_value gfx_snap_to_bitmap(mrb_state* M, mrb_value self) {
  if (!gfx::can_snapshot()) {
    RGSS_warn_stub(M, "Graphics.snap_to_bitmap");
    return mrb_nil_value();
  }
  gfx::Display* const display = get_display(M);
  gfx::Snapshot snap;
  gfx::SnapResult got;
  {
    PixelGcHold hold;
    got = gfx::snapshot_take(display, snap);
  }
  if (got == gfx::SnapResult::kNoScreen)
    return mrb_nil_value();
  if (got != gfx::SnapResult::kOk) {
    RGSS_warn_stub(M, "Graphics.snap_to_bitmap (snapshot failed)");
    return mrb_nil_value();
  }
  const mrb_int w = snap.w;
  const mrb_int h = snap.h;
  RClass* bmp_class = mrb_class_get_under_id(
      M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Bitmap));
  const mrb_value out =
      DataType<Bitmap>::make(M, bmp_class, w, h, kPixelARGB8888);
  Bitmap& b = DataType<Bitmap>::get(M, out);
  const uint32_t stride = snap.stride;
  for (mrb_int y = 0; y < h; ++y) {
    const uint8_t* src = snap.data + static_cast<size_t>(y) * stride;
    uint8_t* dst = b.buffer.data() + static_cast<size_t>(y) * w * 4;
    std::memcpy(dst, src, static_cast<size_t>(w) * 4);
  }
  b.dirty = true;
  gfx::snapshot_release(snap);
  return out;
}

// Slot `i` of a DisplayObj, as an mrb_data_ivar entry (see DISPLAY_IVARS).
constexpr size_t display_slot(size_t i) {
  return offsetof(DisplayObj<1>, iv) + i * sizeof(mrb_value);
}
#ifdef MRB_DATA_IVAR_BY_NAME
// That kill switch names an entry by its "@name" string. Stringifying the name
// here would make bc2cpp read every slot name as a method name (naming_macros),
// so under it the descriptors are empty and the ivars stay in the iv_tbl.
#define DISPLAY_IVAR(name, i) {nullptr, display_slot(i), MRB_DATA_IVAR_VALUE}
#define DISPLAY_IVAR_COUNT(ivars) 0
#else
#define DISPLAY_IVAR(name, i) \
  MRB_DATA_IVAR_ENTRY(name, display_slot(i), MRB_DATA_IVAR_VALUE)
#define DISPLAY_IVAR_COUNT(ivars) (sizeof(ivars) / sizeof(ivars[0]))
#endif
#define DISPLAY_TYPE(name, ivars)                        \
  {name,                                                 \
   free_display,                                         \
   ivars,                                                \
   DISPLAY_IVAR_COUNT(ivars),                            \
   sizeof(DisplayObj<sizeof(ivars) / sizeof(ivars[0])>), \
   nullptr,                                              \
   0}

// What every sprite sets (register_zobj, spr_init, spr_bind_display) or most
// do. tone, color, src_rect, ox/oy, zoom, angle, mirror, blend_type, bush_depth
// and a flash are each set on a few sprites at most, so they take an iv_tbl.
const mrb_data_ivar sprite_ivars[] = {
    DISPLAY_IVAR(x, 0),       DISPLAY_IVAR(y, 1),
    DISPLAY_IVAR(z, 2),       DISPLAY_IVAR(visible, 3),
    DISPLAY_IVAR(bitmap, 4),  DISPLAY_IVAR(_fx_bitmap, 5),
    DISPLAY_IVAR(opacity, 6), DISPLAY_IVAR(viewport, 7),
};
const mrb_data_type sprite_type = DISPLAY_TYPE("RGSS::Sprite", sprite_ivars);

const mrb_data_ivar viewport_ivars[] = {
    DISPLAY_IVAR(x, 0),       DISPLAY_IVAR(y, 1),    DISPLAY_IVAR(z, 2),
    DISPLAY_IVAR(visible, 3), DISPLAY_IVAR(rect, 4), DISPLAY_IVAR(ox, 5),
    DISPLAY_IVAR(oy, 6),      DISPLAY_IVAR(tone, 7), DISPLAY_IVAR(_tone_key, 8),
};
const mrb_data_type viewport_type =
    DISPLAY_TYPE("RGSS::Viewport", viewport_ivars);

#if !defined(WIO_TERMINAL)  // Plane, Tilemap and Window are not built on wio
const mrb_data_ivar plane_ivars[] = {
    DISPLAY_IVAR(x, 0),       DISPLAY_IVAR(y, 1),
    DISPLAY_IVAR(z, 2),       DISPLAY_IVAR(visible, 3),
    DISPLAY_IVAR(bitmap, 4),  DISPLAY_IVAR(_plane_canvas, 5),
    DISPLAY_IVAR(opacity, 6), DISPLAY_IVAR(viewport, 7),
    DISPLAY_IVAR(ox, 8),      DISPLAY_IVAR(oy, 9),
};
const mrb_data_type plane_type = DISPLAY_TYPE("RGSS::Plane", plane_ivars);

const mrb_data_ivar tilemap_ivars[] = {
    DISPLAY_IVAR(x, 0),           DISPLAY_IVAR(y, 1),
    DISPLAY_IVAR(z, 2),           DISPLAY_IVAR(visible, 3),
    DISPLAY_IVAR(viewport, 4),    DISPLAY_IVAR(ox, 5),
    DISPLAY_IVAR(oy, 6),          DISPLAY_IVAR(tileset, 7),
    DISPLAY_IVAR(map_data, 8),    DISPLAY_IVAR(priorities, 9),
    DISPLAY_IVAR(autotiles, 10),  DISPLAY_IVAR(_tm_canvas, 11),
    DISPLAY_IVAR(_tm_anim, 12),   DISPLAY_IVAR(_tm_animated, 13),
    DISPLAY_IVAR(_tm_strips, 14),
};
const mrb_data_type tilemap_type = DISPLAY_TYPE("RGSS::Tilemap", tilemap_ivars);

// A tilemap's priority strips and its "above" layer (tilemap_strip,
// tilemap_ensure_above).
const mrb_data_ivar tilemap_part_ivars[] = {
    DISPLAY_IVAR(x, 0),       DISPLAY_IVAR(y, 1),       DISPLAY_IVAR(z, 2),
    DISPLAY_IVAR(_bitmap, 3), DISPLAY_IVAR(_bucket, 4),
};
const mrb_data_type tilemap_part_type =
    DISPLAY_TYPE("RGSS::Tilemap", tilemap_part_ivars);

const mrb_data_ivar window_ivars[] = {
    DISPLAY_IVAR(x, 0),
    DISPLAY_IVAR(y, 1),
    DISPLAY_IVAR(z, 2),
    DISPLAY_IVAR(visible, 3),
    DISPLAY_IVAR(viewport, 4),
    DISPLAY_IVAR(contents, 5),
    DISPLAY_IVAR(width, 6),
    DISPLAY_IVAR(height, 7),
    DISPLAY_IVAR(ox, 8),
    DISPLAY_IVAR(oy, 9),
    DISPLAY_IVAR(contents_opacity, 10),
    DISPLAY_IVAR(_anim, 11),
    DISPLAY_IVAR(windowskin, 12),
    DISPLAY_IVAR(opacity, 13),
    DISPLAY_IVAR(back_opacity, 14),
    DISPLAY_IVAR(cursor_rect, 15),
    DISPLAY_IVAR(active, 16),
    DISPLAY_IVAR(pause, 17),
    DISPLAY_IVAR(_win_canvas, 18),
    DISPLAY_IVAR(_win_structural, 19),
    DISPLAY_IVAR(_win_struct_key, 20),
};
const mrb_data_type window_type = DISPLAY_TYPE("RGSS::Window", window_ivars);
#endif  // !defined(WIO_TERMINAL)

// Give `self` its payload, before it has a node: a raise until wrap_node leaves
// it disposed, with nothing to leak. A second #initialize keeps the payload.
void display_init(mrb_state* M, mrb_value self, const mrb_data_type* type) {
  DisplayHead* h = static_cast<DisplayHead*>(DATA_PTR(self));
  if (DATA_TYPE(self) != type || !h) {
    h = static_cast<DisplayHead*>(mrb_malloc(M, type->ivar_data_size));
    h->node = nullptr;
    for (size_t i = 0; i < type->ivar_count; ++i)
      *reinterpret_cast<mrb_value*>(reinterpret_cast<char*>(h) +
                                    type->ivars[i].offset) = mrb_undef_value();
    mrb_data_init(self, h, type);
  } else if (h->self != h) {
    h->node = nullptr;  // a copy's node is its original's
  }
  h->self = h;
}

// Bind a node to its mruby wrapper, which the backend invalidates when the node
// goes (gfx::node_released below).
void wrap_node(mrb_state* M, mrb_value self, gfx::Node* obj) {
  static_cast<DisplayHead*>(DATA_PTR(self))->node = obj;
  gfx::node_bind(obj, mrb_ptr(self));
}

// obj_dispose (see bmp_require's own citation, its Bitmap counterpart above)
// nulls the node but leaves the mruby wrapper object alive and
// non-nil, so a setter that read the node directly on an
// already-disposed Sprite/Viewport/Window/Tilemap used to hit a bare
// mrb_assert(obj): a real abort() under this build's -DMRB_DEBUG (the crash
// this fixes -- a battle-loss Game Over disposing the whole scene mid-frame,
// see Scene::Map's own #dispose/#update), and, since mrb_assert compiles away
// to nothing without MRB_DEBUG, an unguarded null-pointer LVGL call otherwise.
// Raises a catchable RGSSError instead, matching real RGSS and bmp_require.
gfx::Node* obj_require(mrb_state* M, mrb_value self) {
  gfx::Node* obj = display_node(self);
  if (!obj) {
    RClass* mod = mrb_module_get_id(M, MRB_SYM(RGSS));
    mrb_raisef(M, mrb_class_get_under_id(M, mod, MRB_SYM(RGSSError)),
               "disposed %s", mrb_obj_classname(M, self));
  }
  return obj;
}

// The one node every game-side display thing hangs off -- viewport frames
// (vp_init) and viewport-less sprites/windows/canvases (parent_object) alike.
gfx::Node* game_root(gfx::Display* disp) {
  return gfx::root(disp);
}

gfx::Node* parent_object(mrb_state* M, mrb_value vp) {
  if (mrb_nil_p(vp))
    return game_root(get_display(M));

  mrb_assert(mrb_type(vp) == MRB_TT_DATA && DATA_TYPE(vp) == &viewport_type);
  return gfx::viewport_content(display_node(vp));
}

// Register a display object for z-ordering and give it a default z of 0.
void register_zobj(mrb_state* M, mrb_value v) {
  mrb_ary_push(M, zorder_objs(M), v);
  mrb_iv_set(M, v, MRB_IVSYM(x), mrb_fixnum_value(0));
  mrb_iv_set(M, v, MRB_IVSYM(y), mrb_fixnum_value(0));
  mrb_iv_set(M, v, MRB_IVSYM(z), mrb_fixnum_value(0));
  update_z(M);
}

mrb_value spr_init(mrb_state* M, mrb_value self) {
  mrb_value vp = mrb_nil_value();
  mrb_get_args(M, "|o", &vp);

  display_init(M, self, &sprite_type);
  gfx::Node* p = gfx::sprite_new(parent_object(M, vp));
  wrap_node(M, self, p);
  register_zobj(M, self);
  // Keep the viewport alive as long as the sprite refers to it.
  mrb_iv_set(M, self, MRB_IVSYM(viewport), vp);
  return self;
}

// Point the sprite's canvas at the bitmap it should display: the assigned
// bitmap directly, or — when the sprite is mirrored — a horizontally-flipped
// scratch copy (LVGL's lv_image has no flip, so mirroring is a software pass).
// The scratch Bitmap is kept in @_mirror_bitmap so it lives as long as the
// sprite and is freed with it. The flip is a snapshot taken here; a sprite that
// redraws its bitmap contents while mirrored must re-assign bitmap= (or set
// mirror= again) to refresh it (tracked in docs/rpgxp-rgss-api-gap.md).
static int clamp_byte(int v) {
  return v < 0 ? 0 : (v > 255 ? 255 : v);
}

// Apply an RGSS Tone to one pixel: desaturate toward its luminance by `gray`,
// then offset each channel. Shared by every composite that can be toned (a
// sprite, a plane, the tilemap), so they cannot drift apart.
static void apply_tone_px(int& r, int& g, int& b, const Tone& t) {
  const int gy = static_cast<int>(t.gray);
  if (gy != 0) {
    const int lum = (r * 77 + g * 150 + b * 29) / 256;
    r += (lum - r) * gy / 255;
    g += (lum - g) * gy / 255;
    b += (lum - b) * gy / 255;
  }
  r = clamp_byte(r + static_cast<int>(t.red));
  g = clamp_byte(g + static_cast<int>(t.green));
  b = clamp_byte(b + static_cast<int>(t.blue));
}

static bool tone_is_set(const Tone& t) {
  return t.red != 0 || t.green != 0 || t.blue != 0 || t.gray != 0;
}

// The tone of the viewport an object was created in, or a neutral tone when it
// has none. RGSS applies this to everything the viewport draws *after* each
// object's own tone/colour, so each composite folds it in as its last step --
// which is why a display object reads it here rather than the viewport reaching
// into the object. See vp_set_tone for how a change is propagated.
static Tone viewport_tone(mrb_state* M, mrb_value vp) {
  Tone t{};
  if (!mrb_test(vp) || !display_node(vp))
    return t;
  const mrb_value tv = mrb_iv_get(M, vp, MRB_IVSYM(tone));
  if (mrb_test(tv) && DATA_PTR(tv))
    t = DataType<Tone>::get(M, tv);
  return t;
}

// Everything spr_bind_display bakes into a sprite's picture besides the
// bitmap's own pixels, captured when the sprite is (re)bound.
struct SpriteFx {
  int cx = 0, cy = 0, cw = 0, ch = 0;  // src_rect (the whole bitmap if none)
  bool mirror = false;
  bool has_tone = false, has_color = false, has_vp_tone = false;
  bool flash_color_on = false, flash_empty = false;
  Tone tn{}, vtn{};
  Color cl{0, 0, 0, 0}, fcl{0, 0, 0, 0};
  int fa = 0, flash_count = 0, flash_dur = 0, bush = 0;
  // Whether any pixel differs from the bitmap's own (crop and mirror only move
  // pixels).
  bool colour() const {
    return has_tone || has_color || has_vp_tone || flash_color_on ||
           flash_empty || bush > 0;
  }
};

// Pixel (x, y) of a sprite's picture, written as `bpp` bytes of B, G, R(, A):
// the bytes bmp_put stores for it in a direct-format scratch bitmap.
inline void sprite_fx_pixel(const Bitmap& src,
                            const SpriteFx& f,
                            int x,
                            int y,
                            unsigned bpp,
                            uint8_t* out) {
  const int srcx = f.cx + (f.mirror ? f.cw - 1 - x : x);
  const int srcy = f.cy + y;
  int r = 0, g = 0, b = 0, a = 0;
  if (srcx >= 0 && srcy >= 0 && srcx < src.width && srcy < src.height)
    bmp_read(src, srcx, srcy, r, g, b, a);
  if (f.has_tone)
    apply_tone_px(r, g, b, f.tn);
  if (f.has_color) {
    const int ca = static_cast<int>(f.cl.alpha);
    r = clamp_byte(r + (static_cast<int>(f.cl.red) - r) * ca / 255);
    g = clamp_byte(g + (static_cast<int>(f.cl.green) - g) * ca / 255);
    b = clamp_byte(b + (static_cast<int>(f.cl.blue) - b) * ca / 255);
  }
  if (f.flash_color_on) {
    r = clamp_byte(r + (static_cast<int>(f.fcl.red) - r) * f.fa / 255);
    g = clamp_byte(g + (static_cast<int>(f.fcl.green) - g) * f.fa / 255);
    b = clamp_byte(b + (static_cast<int>(f.fcl.blue) - b) * f.fa / 255);
  }
  if (f.has_vp_tone)
    apply_tone_px(r, g, b, f.vtn);
  if (f.flash_empty)
    a = a * (f.flash_dur - f.flash_count) / f.flash_dur;
  if (f.bush > 0 && y >= f.ch - f.bush)
    a /= 2;
  out[0] = static_cast<uint8_t>(b);
  out[1] = static_cast<uint8_t>(g);
  out[2] = static_cast<uint8_t>(r);
  if (bpp >= 4)
    out[3] = static_cast<uint8_t>(a);
}

// DRAW_TIME_SPRITE: a sprite whose bitmap is indexed or needs effects is drawn
// through a SpriteView instead of a canvas buffer. The backend asks for the
// rows of each strip it renders (gfx::view_fill), and they are expanded with
// sprite_fx_pixel then, so neither a promoted copy of the bitmap nor an
// @_fx_bitmap exists. The rows are the bytes the scratch bitmap would hold, in
// the same colour format, so the backend blends exactly what it blended before.
// Only an untransformed sprite qualifies: LVGL's software renderer can only
// transform a fully decoded image (see spr_bind_display).
// RGSS_DRAW_TIME_SPRITES=0 (environment or build define) turns it off.
#ifndef RGSS_DRAW_TIME_SPRITES
#define RGSS_DRAW_TIME_SPRITES 1
#endif
static bool draw_time_sprites_enabled() {
#if RGSS_DRAW_TIME_SPRITES
  static const bool on = [] {
    const char* e = std::getenv("RGSS_DRAW_TIME_SPRITES");
    return !(e && std::strcmp(e, "0") == 0);
  }();
  return on;
#else
  return false;
#endif
}

struct SpriteView : gfx::View {
  // Shared with the Ruby Bitmap, so disposing it cannot free pixels a pending
  // draw still reads.
  std::shared_ptr<Bitmap> src;
  SpriteFx fx;
};

// The view owned by a sprite's node (freed with it), created on demand.
SpriteView* sprite_view(gfx::Node* obj, bool create) {
  if (gfx::View* v = gfx::sprite_view(obj))
    return static_cast<SpriteView*>(v);
  if (!create || !gfx::views_ready())
    return nullptr;
  auto* v = new (std::nothrow) SpriteView();
  if (v)
    gfx::sprite_attach_view(obj, v);
  return v;
}

}  // namespace

// GFX_BACKEND's engine side (gfx.hxx).
namespace rgss {
namespace gfx {

// Each wrapped node's RData: null its node so the wrapper (and its later
// dispose/GC) never deletes a freed node. This is what makes it safe to nest
// Sprites inside a Viewport that owns them: whichever wrapper the GC frees
// first, the others are invalidated.
void node_released(void* owner) {
  static_cast<DisplayHead*>(static_cast<struct RData*>(owner)->data)->node =
      nullptr;
}

DrawHold::DrawHold() {
  ++g_pixel_gc_hold;
}

DrawHold::~DrawHold() {
  --g_pixel_gc_hold;
}

int32_t view_chunk_rows(const View& view, int32_t w, unsigned bpp) {
  const SpriteView& v = static_cast<const SpriteView&>(view);
  int32_t chunk = std::max<int32_t>(
      1, static_cast<int32_t>(kSpriteViewChunkBytes / (w * bpp)));
  // A deferred bitmap composes whole rows of its own width (`part` in
  // view_fill), which a sprite drawn narrower than its bitmap would size past
  // the chunk.
  if (v.src->deferred)
    chunk = std::min<int32_t>(
        chunk,
        std::max<int32_t>(1, static_cast<int32_t>(
                                 kSpriteViewChunkBytes /
                                 (static_cast<uint32_t>(v.src->width) * 4u))));
  return chunk;
}

void view_fill(const View& view,
               int32_t x1,
               int32_t x2,
               int32_t y1,
               int32_t rows,
               uint8_t* data,
               uint32_t stride,
               unsigned bpp) {
  const SpriteView& v = static_cast<const SpriteView&>(view);
  const Bitmap* sb = v.src.get();
  SpriteFx f = v.fx;
  // A deferred bitmap's rows are composed for this chunk only, and read from
  // there as if they were the bitmap.
  std::unique_ptr<Bitmap> part;
  if (const std::shared_ptr<DeferredList> list = sb->deferred) {
    part = std::make_unique<Bitmap>(sb->width, rows, kPixelARGB8888);
    deferred_rows(*list, sb->height, f.cy + y1, *part);
    f.cy = -y1;
    sb = part.get();
  }
  const Bitmap& src = *sb;
  const bool plain = !f.colour();
  for (int32_t r = 0; r < rows; ++r) {
    uint8_t* d = data + static_cast<size_t>(r) * stride;
    const int y = y1 + r;
    for (int32_t x = x1; x <= x2; ++x, d += bpp) {
      if (!plain) {
        sprite_fx_pixel(src, f, x, y, bpp, d);
        continue;
      }
      // Crop and mirror only: the source pixel's bytes, or transparent black
      // outside the bitmap.
      const int sx = f.cx + (f.mirror ? f.cw - 1 - x : x);
      const int sy = f.cy + y;
      if (sx < 0 || sy < 0 || sx >= src.width || sy >= src.height) {
        std::memset(d, 0, bpp);
      } else if (src.indexed()) {
        std::memcpy(
            d,
            src.pal() + src.px()[static_cast<size_t>(sy) * src.width + sx] * 4u,
            bpp);
      } else {
        const unsigned sbpp = pixel_size(src.format);
        const uint8_t* p = src.buffer.data() +
                           (static_cast<size_t>(sy) * src.width + sx) * sbpp;
        std::memcpy(d, p, std::min(bpp, sbpp));
        if (bpp > sbpp)
          d[3] = 255;
      }
    }
  }
}

void view_destroy(View* v) {
  delete static_cast<SpriteView*>(v);
}

}  // namespace gfx
}  // namespace rgss

namespace {

// Point the sprite's canvas at the bitmap it should display: the assigned
// bitmap directly, a SpriteView of it (see DRAW_TIME_SPRITE), or -- for a
// transformed sprite that needs effects -- a scratch copy with them baked in,
// kept in @_fx_bitmap. Effects are a snapshot taken here; a sprite that
// mutates its tone/color in place must re-assign tone= / color= to refresh
// (tracked in the gap doc).
void spr_bind_display(mrb_state* M, mrb_value self, gfx::Node* obj) {
  const mrb_value bmp_v = mrb_iv_get(M, self, MRB_IVSYM(bitmap));
  if (mrb_nil_p(bmp_v))
    return;
  Bitmap& src = DataType<Bitmap>::raw(M, bmp_v);
  // The draw-time path below reads the pixels without settling them.
  ensure_pixels(src);

  SpriteFx f;
  f.mirror = mrb_test(mrb_iv_get(M, self, MRB_IVSYM(mirror)));
  const mrb_value tone_v = mrb_iv_get(M, self, MRB_IVSYM(tone));
  const mrb_value color_v = mrb_iv_get(M, self, MRB_IVSYM(color));
  if (mrb_test(tone_v) && DATA_PTR(tone_v))
    f.tn = DataType<Tone>::get(M, tone_v);
  if (mrb_test(color_v) && DATA_PTR(color_v))
    f.cl = DataType<Color>::get(M, color_v);
  f.has_tone = tone_is_set(f.tn);
  f.has_color = f.cl.alpha != 0;
  // The viewport's tone applies to everything it draws, so it is folded into
  // this composite after the sprite's own tone/colour/flash (RGSS tints the
  // viewport's contents, not its sources).
  f.vtn = viewport_tone(M, mrb_iv_get(M, self, MRB_IVSYM(viewport)));
  f.has_vp_tone = tone_is_set(f.vtn);

  // bush_depth: the bottom N rows are drawn at half opacity, so a character
  // wading through bushes fades out below the waist.
  const mrb_value bush_v = mrb_iv_get(M, self, MRB_IVSYM(bush_depth));
  f.bush = mrb_test(bush_v) ? mrb_as_int(M, bush_v) : 0;

  // flash: a timed colour pulse (Sprite#flash) that decays over its duration,
  // advanced one frame per Sprite#update. A colour flash overlays that colour
  // at a fading alpha; a nil-colour ("empty") flash instead blinks the sprite
  // out and back in.
  const mrb_value fcnt_v = mrb_iv_get(M, self, MRB_IVSYM(flash_count));
  const mrb_value fdur_v = mrb_iv_get(M, self, MRB_IVSYM(flash_duration));
  const mrb_value fcol_v = mrb_iv_get(M, self, MRB_IVSYM(flash_color));
  f.flash_count = mrb_test(fcnt_v) ? mrb_as_int(M, fcnt_v) : 0;
  f.flash_dur = mrb_test(fdur_v) ? mrb_as_int(M, fdur_v) : 0;
  const bool flash_on = f.flash_count > 0 && f.flash_dur > 0;
  f.flash_color_on = flash_on && mrb_test(fcol_v) && DATA_PTR(fcol_v);
  f.flash_empty = flash_on && !f.flash_color_on;
  if (f.flash_color_on)
    f.fcl = DataType<Color>::get(M, fcol_v);
  // Colour flash intensity fades from full (count == duration) to nothing.
  f.fa = f.flash_color_on
             ? static_cast<int>(f.fcl.alpha) * f.flash_count / f.flash_dur
             : 0;

  // src_rect: display only a sub-region of the bitmap (character-animation
  // cells set this every frame). A non-default rect crops to (cx, cy, cw, ch).
  f.cw = src.width;
  f.ch = src.height;
  bool cropped = false;
  const mrb_value sr_v = mrb_iv_get(M, self, MRB_IVSYM(src_rect));
  if (mrb_test(sr_v) && DATA_PTR(sr_v)) {
    Rect& sr = DataType<Rect>::get(M, sr_v);
    if (sr.width > 0 && sr.height > 0 &&
        (sr.x != 0 || sr.y != 0 || sr.width != src.width ||
         sr.height != src.height)) {
      f.cx = sr.x;
      f.cy = sr.y;
      f.cw = sr.width;
      f.ch = sr.height;
      cropped = true;
    }
  }
  const bool needs_fx = cropped || f.mirror || f.colour();

  if ((needs_fx || src.indexed() || src.deferred) &&
      draw_time_sprites_enabled() && !gfx::sprite_transformed(obj)) {
    if (SpriteView* v = sprite_view(obj, true)) {
      mrb_iv_set(M, self, MRB_IVSYM(_fx_bitmap), mrb_nil_value());
      v->src = *reinterpret_cast<std::shared_ptr<Bitmap>*>(DATA_PTR(bmp_v));
      v->fx = f;
      gfx::sprite_show_view(obj, v, src.direct_format, f.cw, f.ch);
      src.dirty = true;
      return;
    }
  }
  if (SpriteView* v = sprite_view(obj, false))
    v->src.reset();
  settle_for_access(src);

  if (needs_fx) {
    // Reuse the scratch bitmap when its size still matches (src_rect changes
    // every frame, so re-allocating here would churn the GC).
    mrb_value fx_v = mrb_iv_get(M, self, MRB_IVSYM(_fx_bitmap));
    Bitmap* fxp = nullptr;
    if (mrb_test(fx_v) && DATA_PTR(fx_v)) {
      Bitmap& e = DataType<Bitmap>::get(M, fx_v);
      if (e.width == f.cw && e.height == f.ch && e.format == src.direct_format)
        fxp = &e;
    }
    if (!fxp) {
      RClass* bmp_class = mrb_class_get_under_id(
          M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Bitmap));
      fx_v =
          DataType<Bitmap>::make(M, bmp_class, f.cw, f.ch, src.direct_format);
      mrb_iv_set(M, self, MRB_IVSYM(_fx_bitmap), fx_v);
      fxp = &DataType<Bitmap>::get(M, fx_v);
    }
    Bitmap& fx = *fxp;
    const unsigned bpp = pixel_size(fx.format);
    uint8_t* d = fx.buffer.data();
    for (int y = 0; y < f.ch; ++y)
      for (int x = 0; x < f.cw; ++x, d += bpp)
        sprite_fx_pixel(src, f, x, y, bpp, d);
    fx.dirty = true;
    if (fx.buffer.empty())
      gfx::sprite_clear(obj);
    else
      gfx::sprite_set_pixels(obj, fx.buffer.data(), f.cw, f.ch, fx.format);
  } else {
    mrb_iv_set(M, self, MRB_IVSYM(_fx_bitmap), mrb_nil_value());
    // Shown whole, the bitmap itself becomes the canvas buffer. An empty
    // bitmap has no buffer, which LVGL's canvas asserts against (a
    // halt on the Wio); no image source draws the same nothing.
    promote_to_direct(src);
    if (src.buffer.empty())
      gfx::sprite_clear(obj);
    else
      gfx::sprite_set_pixels(obj, src.buffer.data(), src.width, src.height,
                             src.format);
  }
  // Repaint on the next Graphics.update, even if the contents were drawn before
  // the bitmap was attached to this sprite.
  src.dirty = true;
}

mrb_value spr_set_bmp(mrb_state* M, mrb_value self) {
  mrb_value bmp;
  mrb_get_args(M, "o", &bmp);
  return rgss::sprite_bitmap_set_direct(M, self, bmp);
}

// RGSS Sprite#opacity= (0..255). The node's opacity multiplies the bitmap's
// own alpha at blit time, which is exactly RGSS's per-sprite opacity. The value
// is clamped and mirrored into @opacity so the Ruby reader (defaulting to 255)
// returns what was set. A fresh sprite needs no explicit call: LVGL's default
// object opacity is fully opaque, matching RGSS's 255 default.
mrb_value spr_set_opacity_body(mrb_state* M, mrb_value self, mrb_int opa);

mrb_value spr_set_opacity_native_body(mrb_state* M,
                                      mrb_value self,
                                      mrb_int opa) {
  return spr_set_opacity_body(M, self, opa);
}

mrb_value spr_set_opacity(mrb_state* M, mrb_value self) {
  mrb_int opa;
  mrb_get_args(M, "i", &opa);
  return spr_set_opacity_native_body(M, self, opa);
}

mrb_value spr_set_opacity_body(mrb_state* M, mrb_value self, mrb_int opa) {
  if (opa < 0)
    opa = 0;
  else if (opa > 255)
    opa = 255;
  gfx::Node* obj = obj_require(M, self);
  // Per-frame render code pokes opacity unconditionally (the screen fade and
  // flash sprites, every idle frame, same value). LVGL's local-style setter
  // refreshes -- and so invalidates -- the object without comparing values,
  // and a full-screen sprite invalidated every frame re-renders the whole
  // display: measured ~13ms of the frame on the Android test device. The
  // mirrored ivar is authoritative (every write goes through here), so an
  // equal value can skip the style set entirely.
  mrb_value cur = mrb_iv_get(M, self, MRB_IVSYM(opacity));
  if (mrb_fixnum_p(cur) && mrb_fixnum(cur) == opa)
    return self;
  gfx::sprite_set_opacity(obj, static_cast<uint8_t>(opa));
  mrb_iv_set(M, self, MRB_IVSYM(opacity), mrb_fixnum_value(opa));
  return self;
}

// A SpriteView can only be drawn untransformed (see DRAW_TIME_SPRITE), so a
// zoom or rotation that starts or ends one re-binds the sprite.
void spr_retransform(mrb_state* M, mrb_value self, gfx::Node* obj, bool was) {
  if (was != gfx::sprite_transformed(obj))
    spr_bind_display(M, self, obj);
}

// RGSS Sprite#zoom_x= / #zoom_y= (a float multiplier, 1.0 = normal size). A
// sprite node scales its content by an integer factor where gfx::kScaleOne
// (256) == 1.0. Convert the RGSS float to that fixed point and apply it; the
// float is mirrored into @zoom_x/@zoom_y so the Ruby reader (defaulting to 1.0)
// returns it. A fresh sprite is already unscaled, matching RGSS's 1.0 default.
// mruby's "f" coerces an Integer argument (e.g. `zoom_x = 1`) to Float.
mrb_value spr_set_zoom_x_native_body(mrb_state* M, mrb_value self, double z) {
  if (z < 0.0)
    z = 0.0;
  gfx::Node* obj = obj_require(M, self);
  const bool was = gfx::sprite_transformed(obj);
  gfx::sprite_set_scale_x(obj, static_cast<uint32_t>(z * gfx::kScaleOne + 0.5));
  spr_retransform(M, self, obj, was);
  mrb_iv_set(M, self, MRB_IVSYM(zoom_x), rgss::num_value(M, z));
  return self;
}

mrb_value spr_set_zoom_x(mrb_state* M, mrb_value self) {
  mrb_value zv;
  mrb_get_args(M, "o", &zv);
  const double z = rgss::num_arg(M, zv);
  return spr_set_zoom_x_native_body(M, self, z);
}

mrb_value spr_set_zoom_y_native_body(mrb_state* M, mrb_value self, double z) {
  if (z < 0.0)
    z = 0.0;
  gfx::Node* obj = obj_require(M, self);
  const bool was = gfx::sprite_transformed(obj);
  gfx::sprite_set_scale_y(obj, static_cast<uint32_t>(z * gfx::kScaleOne + 0.5));
  spr_retransform(M, self, obj, was);
  mrb_iv_set(M, self, MRB_IVSYM(zoom_y), rgss::num_value(M, z));
  return self;
}

mrb_value spr_set_zoom_y(mrb_state* M, mrb_value self) {
  mrb_value zv;
  mrb_get_args(M, "o", &zv);
  const double z = rgss::num_arg(M, zv);
  return spr_set_zoom_y_native_body(M, self, z);
}

// RGSS Sprite#angle= (degrees, counter-clockwise, float). A node's rotation
// is in 0.1-degree units, clockwise, normalised to [0, 3600), so negate and
// scale. RGSS rotates about the sprite's (ox, oy) origin, which is the LVGL
// image pivot (default 0,0). The @ox/@oy ivars are read here so a script that
// sets the origin before rotating gets the right pivot; a later ox=/oy= that
// must re-pivot simply re-assigns angle. The float is mirrored into @angle for
// the Ruby reader.
mrb_value spr_set_angle_native_body(mrb_state* M, mrb_value self, double deg) {
  gfx::Node* obj = obj_require(M, self);
  long tenths = ::lround(-deg * 10.0) % 3600;
  if (tenths < 0)
    tenths += 3600;
  const mrb_value ox = mrb_iv_get(M, self, MRB_IVSYM(ox));
  const mrb_value oy = mrb_iv_get(M, self, MRB_IVSYM(oy));
  gfx::sprite_set_pivot(
      obj, mrb_nil_p(ox) ? 0 : static_cast<int32_t>(mrb_as_int(M, ox)),
      mrb_nil_p(oy) ? 0 : static_cast<int32_t>(mrb_as_int(M, oy)));
  const bool was = gfx::sprite_transformed(obj);
  gfx::sprite_set_rotation(obj, static_cast<int32_t>(tenths));
  spr_retransform(M, self, obj, was);
  mrb_iv_set(M, self, MRB_IVSYM(angle), rgss::num_value(M, deg));
  return self;
}

mrb_value spr_set_angle(mrb_state* M, mrb_value self) {
  mrb_value degv;
  mrb_get_args(M, "o", &degv);
  const double deg = rgss::num_arg(M, degv);
  return spr_set_angle_native_body(M, self, deg);
}

// RGSS Sprite#mirror= (horizontal flip). LVGL's lv_image has no flip, so this
// re-binds the canvas to a flipped scratch copy of the bitmap (or back to the
// bitmap itself) via spr_bind_display.
mrb_value spr_set_mirror_native_body(mrb_state* M, mrb_value self, mrb_bool m) {
  mrb_iv_set(M, self, MRB_IVSYM(mirror), mrb_bool_value(m));
  gfx::Node* obj = obj_require(M, self);
  spr_bind_display(M, self, obj);
  return self;
}

mrb_value spr_set_mirror(mrb_state* M, mrb_value self) {
  mrb_bool m;
  mrb_get_args(M, "b", &m);
  return spr_set_mirror_native_body(M, self, m);
}

// RGSS Sprite#tone= (a Tone tint) and #color= (a Color overlay). Both are baked
// into the sprite's pixels by spr_bind_display, so assigning one re-composites.
mrb_value spr_set_tone_body(mrb_state* M, mrb_value self, mrb_value v);

mrb_value spr_set_tone_native_body(mrb_state* M, mrb_value self, mrb_value v) {
  return spr_set_tone_body(M, self, v);
}

mrb_value spr_set_tone(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  return spr_set_tone_native_body(M, self, v);
}

mrb_value spr_set_tone_body(mrb_state* M, mrb_value self, mrb_value v) {
  mrb_iv_set(M, self, MRB_IVSYM(tone), v);
  gfx::Node* obj = obj_require(M, self);
  spr_bind_display(M, self, obj);
  return v;
}

mrb_value spr_set_color(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  return rgss::sprite_color_set_direct(M, self, v);
}

// RGSS Sprite#src_rect= displays only a sub-rectangle of the bitmap.
mrb_value spr_set_src_rect_native_body(mrb_state* M,
                                       mrb_value self,
                                       mrb_value v) {
  mrb_iv_set(M, self, MRB_IVSYM(src_rect), v);
  gfx::Node* obj = obj_require(M, self);
  spr_bind_display(M, self, obj);
  return v;
}

mrb_value spr_set_src_rect(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  return spr_set_src_rect_native_body(M, self, v);
}

// Per-frame tick: stock scripts (Sprite_Character etc.) mutate src_rect in
// place via `src_rect.set(...)` each frame, which does not call src_rect=, so a
// sprite that uses src_rect re-composites here to pick that up (and any
// tone/color change). An active flash also decays one frame here. Sprites with
// neither need no per-frame work.
mrb_value spr_update(mrb_state* M, mrb_value self) {
  bool recomposite = false;

  // Advance an active flash: it fades one frame per update and clears (dropping
  // its colour) once the duration runs out.
  const mrb_value fcnt = mrb_iv_get(M, self, MRB_IVSYM(flash_count));
  int fc = mrb_test(fcnt) ? mrb_as_int(M, fcnt) : 0;
  if (fc > 0) {
    --fc;
    mrb_iv_set(M, self, MRB_IVSYM(flash_count), mrb_fixnum_value(fc));
    if (fc == 0)
      mrb_iv_set(M, self, MRB_IVSYM(flash_color), mrb_nil_value());
    recomposite = true;
  }

  const mrb_value sr = mrb_iv_get(M, self, MRB_IVSYM(src_rect));
  if (mrb_test(sr) && DATA_PTR(sr)) {
    Rect& r = DataType<Rect>::get(M, sr);
    if (r.width > 0 && r.height > 0)
      recomposite = true;
  }

  if (recomposite) {
    gfx::Node* obj = display_node(self);
    if (obj)
      spr_bind_display(M, self, obj);
  }
  return self;
}

// RGSS Sprite#blend_type= (0 normal, 1 add, 2 subtract) maps onto the sprite
// node's blend mode, which the backend uses when drawing it over the scene.
mrb_value spr_set_blend_type_native_body(mrb_state* M,
                                         mrb_value self,
                                         mrb_int t) {
  gfx::Blend mode = gfx::Blend::kNormal;
  if (t == 1)
    mode = gfx::Blend::kAdd;
  else if (t == 2)
    mode = gfx::Blend::kSubtract;
  gfx::Node* obj = obj_require(M, self);
  gfx::sprite_set_blend(obj, mode);
  mrb_iv_set(M, self, MRB_IVSYM(blend_type), mrb_fixnum_value(t));
  return self;
}

mrb_value spr_set_blend_type(mrb_state* M, mrb_value self) {
  mrb_int t;
  mrb_get_args(M, "i", &t);
  return spr_set_blend_type_native_body(M, self, t);
}

// RGSS Sprite#bush_depth= fades the bottom N rows of the sprite; baked into the
// composite by spr_bind_display, so assigning it re-composites.
mrb_value spr_set_bush_depth_native_body(mrb_state* M,
                                         mrb_value self,
                                         mrb_int d) {
  mrb_iv_set(M, self, MRB_IVSYM(bush_depth), mrb_fixnum_value(d));
  gfx::Node* obj = obj_require(M, self);
  spr_bind_display(M, self, obj);
  return self;
}

mrb_value spr_set_bush_depth(mrb_state* M, mrb_value self) {
  mrb_int d;
  mrb_get_args(M, "i", &d);
  return spr_set_bush_depth_native_body(M, self, d);
}

// RGSS Sprite#flash(color, duration) starts a timed colour pulse; a nil colour
// is an "empty" flash that blinks the sprite out. The state is baked into the
// composite by spr_bind_display and decayed each frame by spr_update.
mrb_value spr_flash(mrb_state* M, mrb_value self) {
  mrb_value color;
  mrb_int duration;
  mrb_get_args(M, "oi", &color, &duration);
  return rgss::sprite_flash_direct(M, self, color, duration);
}

mrb_value obj_set_x(mrb_state* M, mrb_value self) {
  mrb_int x;
  mrb_get_args(M, "i", &x);
  return rgss::object_x_set_direct(M, self, x);
}

mrb_value obj_set_y(mrb_state* M, mrb_value self) {
  mrb_int y;
  mrb_get_args(M, "i", &y);
  return rgss::object_y_set_direct(M, self, y);
}

mrb_value obj_set_z(mrb_state* M, mrb_value self) {
  mrb_int z;
  mrb_get_args(M, "i", &z);
  return rgss::object_z_set_direct(M, self, z);
}

// Shared visible= for Sprite and Viewport: LVGL's HIDDEN flag also hides the
// whole child subtree, so hiding a Viewport hides everything drawn in it.
mrb_value obj_set_visible(mrb_state* M, mrb_value self) {
  mrb_bool v;
  mrb_get_args(M, "b", &v);
  return rgss::object_visible_set_direct(M, self, v);
}

mrb_value obj_visible(mrb_state* M, mrb_value self) {
  mrb_value v = mrb_iv_get(M, self, MRB_IVSYM(visible));
  return mrb_nil_p(v) ? mrb_true_value() : v;
}

#if !defined(WIO_TERMINAL)  // Plane: dead weight on wio, no Ruby path ever
                            // instantiates it
// ---- Plane ----------------------------------------------------------------

// Redraw the plane's canvas: fill it by tiling the source bitmap, wrapping the
// ox/oy scroll around the bitmap's size. The canvas buffer is a scratch Bitmap
// (@_plane_canvas) sized to the viewport; bmp_read/bmp_put bridge any source /
// canvas format difference. The canvas is invalidated directly (its backing
// buffer is not the sprite @bitmap that Graphics.update's dirty sweep watches).
void plane_retile(mrb_state* M, mrb_value self) {
  gfx::Node* obj = display_node(self);
  if (!obj)
    return;
  const mrb_value canvas_v = mrb_iv_get(M, self, MRB_IVSYM(_plane_canvas));
  if (mrb_nil_p(canvas_v))
    return;
  Bitmap& dst = DataType<Bitmap>::get(M, canvas_v);
  const mrb_value bmp_v = mrb_iv_get(M, self, MRB_IVSYM(bitmap));
  if (mrb_nil_p(bmp_v)) {
    std::fill(dst.buffer.begin(), dst.buffer.end(), static_cast<uint8_t>(0));
    gfx::node_invalidate(obj);
    return;
  }
  Bitmap& src = DataType<Bitmap>::get(M, bmp_v);
  if (src.width <= 0 || src.height <= 0) {
    std::fill(dst.buffer.begin(), dst.buffer.end(), static_cast<uint8_t>(0));
    gfx::node_invalidate(obj);
    return;
  }
  const mrb_int ox = mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(ox)));
  const mrb_int oy = mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(oy)));

  // zoom_x/zoom_y scale the tiled pattern (nearest-neighbour): a zoom of 2.0
  // samples the source at half the rate, so the bitmap appears twice as large.
  // A non-positive or absent zoom is treated as 1.0 (the fast integer path).
  const mrb_value zx_v = mrb_iv_get(M, self, MRB_IVSYM(zoom_x));
  const mrb_value zy_v = mrb_iv_get(M, self, MRB_IVSYM(zoom_y));
  double zx = mrb_test(zx_v) ? rgss::num_arg(M, zx_v) : 1.0;
  double zy = mrb_test(zy_v) ? rgss::num_arg(M, zy_v) : 1.0;
  if (zx <= 0.0)
    zx = 1.0;
  if (zy <= 0.0)
    zy = 1.0;
  const bool scaled = zx != 1.0 || zy != 1.0;

  // Tone (grey desaturation + RGB offset) and colour overlay are baked into the
  // tiled buffer per pixel, the same way Sprite does — so a tinted fog/parallax
  // Plane renders its tint. (Same maths as spr_bind_display.)
  const mrb_value tone_v = mrb_iv_get(M, self, MRB_IVSYM(tone));
  const mrb_value color_v = mrb_iv_get(M, self, MRB_IVSYM(color));
  Tone tn{};
  Color cl{0, 0, 0, 0};
  if (mrb_test(tone_v) && DATA_PTR(tone_v))
    tn = DataType<Tone>::get(M, tone_v);
  if (mrb_test(color_v) && DATA_PTR(color_v))
    cl = DataType<Color>::get(M, color_v);
  const bool has_tone = tone_is_set(tn);
  const bool has_color = cl.alpha != 0;
  const int ca = static_cast<int>(cl.alpha);
  // ...and then the viewport's tone over the result, as for a sprite.
  const Tone vtn = viewport_tone(M, mrb_iv_get(M, self, MRB_IVSYM(viewport)));
  const bool has_vp_tone = tone_is_set(vtn);

  for (int y = 0; y < dst.height; ++y) {
    const int syb = scaled ? static_cast<int>(std::floor((y + oy) / zy))
                           : static_cast<int>(y + oy);
    const int sy = (syb % src.height + src.height) % src.height;
    for (int x = 0; x < dst.width; ++x) {
      const int sxb = scaled ? static_cast<int>(std::floor((x + ox) / zx))
                             : static_cast<int>(x + ox);
      const int sx = (sxb % src.width + src.width) % src.width;
      int r, g, b, a;
      bmp_read(src, sx, sy, r, g, b, a);
      if (has_tone)
        apply_tone_px(r, g, b, tn);
      if (has_color) {
        r = clamp_byte(r + (static_cast<int>(cl.red) - r) * ca / 255);
        g = clamp_byte(g + (static_cast<int>(cl.green) - g) * ca / 255);
        b = clamp_byte(b + (static_cast<int>(cl.blue) - b) * ca / 255);
      }
      if (has_vp_tone)
        apply_tone_px(r, g, b, vtn);
      bmp_put(dst, x, y, r, g, b, a);
    }
  }
  gfx::node_invalidate(obj);
}

mrb_value plane_init(mrb_state* M, mrb_value self) {
  mrb_value vp = mrb_nil_value();
  mrb_get_args(M, "|o", &vp);

  mrb_int w = 0, h = 0;
  if (mrb_nil_p(vp)) {
    int32_t dw, dh;
    gfx::display_size(get_display(M), dw, dh);
    w = dw;
    h = dh;
  } else {
    Rect& r = DataType<Rect>::get(M, mrb_iv_get(M, vp, MRB_IVSYM(rect)));
    w = r.width;
    h = r.height;
  }
  if (w <= 0)
    w = 1;
  if (h <= 0)
    h = 1;

  display_init(M, self, &plane_type);
  gfx::Node* c = gfx::sprite_new(parent_object(M, vp));
  wrap_node(M, self, c);
  register_zobj(M, self);
  gfx::node_set_pos(c, 0, 0);

  RClass* bmp_class = mrb_class_get_under_id(
      M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Bitmap));
  const mrb_value canvas_v =
      DataType<Bitmap>::make(M, bmp_class, w, h, kPixelARGB8888);
  Bitmap& canvas = DataType<Bitmap>::get(M, canvas_v);
  std::fill(canvas.buffer.begin(), canvas.buffer.end(),
            static_cast<uint8_t>(0));
  gfx::sprite_set_pixels(c, canvas.buffer.data(), w, h, kPixelARGB8888);

  // Hold the canvas buffer (a Bitmap) and the viewport on the plane so the GC
  // keeps them alive for its lifetime.
  mrb_iv_set(M, self, MRB_IVSYM(_plane_canvas), canvas_v);
  mrb_iv_set(M, self, MRB_IVSYM(viewport), vp);
  mrb_iv_set(M, self, MRB_IVSYM(bitmap), mrb_nil_value());
  mrb_iv_set(M, self, MRB_IVSYM(ox), mrb_fixnum_value(0));
  mrb_iv_set(M, self, MRB_IVSYM(oy), mrb_fixnum_value(0));
  return self;
}

mrb_value plane_set_bmp_native_body(mrb_state* M,
                                    mrb_value self,
                                    mrb_value bmp) {
  mrb_iv_set(M, self, MRB_IVSYM(bitmap), bmp);
  plane_retile(M, self);
  return bmp;
}

mrb_value plane_set_bmp(mrb_state* M, mrb_value self) {
  mrb_value bmp;
  mrb_get_args(M, "o", &bmp);
  return plane_set_bmp_native_body(M, self, bmp);
}

// Same same-value guard as Tilemap#ox=/#oy= (see the comment there): real
// RGSS reassigns a Plane's ox/oy every frame regardless of whether it moved
// (a fog/parallax layer scrolling with the map), and this engine's retile is
// a CPU-side re-composite rather than a cheap draw-time offset, so without
// this guard a stationary Plane still pays a full retile every frame.
mrb_value plane_set_ox_native_body(mrb_state* M, mrb_value self, mrb_int ox) {
  const mrb_value cur = mrb_iv_get(M, self, MRB_IVSYM(ox));
  if (mrb_fixnum_p(cur) && mrb_fixnum(cur) == ox)
    return self;
  mrb_iv_set(M, self, MRB_IVSYM(ox), mrb_fixnum_value(ox));
  plane_retile(M, self);
  return self;
}

mrb_value plane_set_ox(mrb_state* M, mrb_value self) {
  mrb_int ox;
  mrb_get_args(M, "i", &ox);
  return plane_set_ox_native_body(M, self, ox);
}

mrb_value plane_set_oy_native_body(mrb_state* M, mrb_value self, mrb_int oy) {
  const mrb_value cur = mrb_iv_get(M, self, MRB_IVSYM(oy));
  if (mrb_fixnum_p(cur) && mrb_fixnum(cur) == oy)
    return self;
  mrb_iv_set(M, self, MRB_IVSYM(oy), mrb_fixnum_value(oy));
  plane_retile(M, self);
  return self;
}

mrb_value plane_set_oy(mrb_state* M, mrb_value self) {
  mrb_int oy;
  mrb_get_args(M, "i", &oy);
  return plane_set_oy_native_body(M, self, oy);
}

// Plane#tone= / #color= tint the tiled buffer (baked in by plane_retile), so a
// fog/parallax Plane re-tiles with its new tint on assign.
mrb_value plane_set_tone_native_body(mrb_state* M,
                                     mrb_value self,
                                     mrb_value v) {
  mrb_iv_set(M, self, MRB_IVSYM(tone), v);
  plane_retile(M, self);
  return v;
}

mrb_value plane_set_tone(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  return plane_set_tone_native_body(M, self, v);
}

mrb_value plane_set_color(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  return rgss::plane_color_set_direct(M, self, v);
}

// Plane#zoom_x= / #zoom_y= scale the tiled pattern; plane_retile samples the
// source at the reciprocal rate, so assigning a zoom re-tiles.
mrb_value plane_set_zoom_x_native_body(mrb_state* M, mrb_value self, double z) {
  mrb_iv_set(M, self, MRB_IVSYM(zoom_x), rgss::num_value(M, z));
  plane_retile(M, self);
  return self;
}

mrb_value plane_set_zoom_x(mrb_state* M, mrb_value self) {
  mrb_value zv;
  mrb_get_args(M, "o", &zv);
  const double z = rgss::num_arg(M, zv);
  return plane_set_zoom_x_native_body(M, self, z);
}

mrb_value plane_set_zoom_y_native_body(mrb_state* M, mrb_value self, double z) {
  mrb_iv_set(M, self, MRB_IVSYM(zoom_y), rgss::num_value(M, z));
  plane_retile(M, self);
  return self;
}

mrb_value plane_set_zoom_y(mrb_state* M, mrb_value self) {
  mrb_value zv;
  mrb_get_args(M, "o", &zv);
  const double z = rgss::num_arg(M, zv);
  return plane_set_zoom_y_native_body(M, self, z);
}
#endif  // !defined(WIO_TERMINAL)

// ---- Tilemap --------------------------------------------------------------

// Tilemap and Window are compiled out on wio: its only maker,
// RPG2k, draws with its own tilemap and RPG2k::Window. The classes stay, with
// an initialize that raises (not_compiled_init).
#if !defined(WIO_TERMINAL)

// One RGSS map tile is 32x32 px; a tileset is 8 tiles (256 px) wide.
static const int TILE_SIZE = 32;
static const int TILESET_COLS = 8;

// Alpha-blended copy of a src region into dst (used to stack the map's tile
// layers, where upper-layer tiles are partly transparent).
static void blit_blend(Bitmap& dst,
                       int dx,
                       int dy,
                       const Bitmap& src,
                       int sx,
                       int sy,
                       int sw,
                       int sh) {
  for (int j = 0; j < sh; ++j) {
    const int ry = dy + j, syy = sy + j;
    if (ry < 0 || ry >= dst.height || syy < 0 || syy >= src.height)
      continue;
    for (int i = 0; i < sw; ++i) {
      const int rx = dx + i, sxx = sx + i;
      if (rx < 0 || rx >= dst.width || sxx < 0 || sxx >= src.width)
        continue;
      int r, g, b, a;
      bmp_read(src, sxx, syy, r, g, b, a);
      if (a <= 0)
        continue;
      if (a >= 255) {
        bmp_put(dst, rx, ry, r, g, b, 255);
        continue;
      }
      int dr, dg, db, da;
      bmp_read(dst, rx, ry, dr, dg, db, da);
      const int inv = 255 - a;
      bmp_put(dst, rx, ry, (r * a + dr * inv) / 255, (g * a + dg * inv) / 255,
              (b * a + db * inv) / 255, std::max(da, a));
    }
  }
}

// RMXP autotile quad table: 48 shapes x 4 quads (TL, TR, BL, BR), each the
// source (x,y) of a 16x16 piece in the 96x128 autotile bitmap. Derived from
// mkxp (Ancurio/mkxp, src/autotiles.cpp); the .5 texel-centre offsets there are
// floored for CPU sampling.
static const int AUTOTILE_QUADS[48][4][2] = {
    {{32, 64}, {48, 64}, {32, 80}, {48, 80}},
    {{64, 0}, {48, 64}, {32, 80}, {48, 80}},
    {{32, 64}, {80, 0}, {32, 80}, {48, 80}},
    {{64, 0}, {80, 0}, {32, 80}, {48, 80}},
    {{32, 64}, {48, 64}, {32, 80}, {80, 16}},
    {{64, 0}, {48, 64}, {32, 80}, {80, 16}},
    {{32, 64}, {80, 0}, {32, 80}, {80, 16}},
    {{64, 0}, {80, 0}, {32, 80}, {80, 16}},
    {{32, 64}, {48, 64}, {64, 16}, {48, 80}},
    {{64, 0}, {48, 64}, {64, 16}, {48, 80}},
    {{32, 64}, {80, 0}, {64, 16}, {48, 80}},
    {{64, 0}, {80, 0}, {64, 16}, {48, 80}},
    {{32, 64}, {48, 64}, {64, 16}, {80, 16}},
    {{64, 0}, {48, 64}, {64, 16}, {80, 16}},
    {{32, 64}, {80, 0}, {64, 16}, {80, 16}},
    {{64, 0}, {80, 0}, {64, 16}, {80, 16}},
    {{0, 64}, {16, 64}, {0, 80}, {16, 80}},
    {{0, 64}, {80, 0}, {0, 80}, {16, 80}},
    {{0, 64}, {16, 64}, {0, 80}, {80, 16}},
    {{0, 64}, {80, 0}, {0, 80}, {80, 16}},
    {{32, 32}, {48, 32}, {32, 48}, {48, 48}},
    {{32, 32}, {48, 32}, {32, 48}, {80, 16}},
    {{32, 32}, {48, 32}, {64, 16}, {48, 48}},
    {{32, 32}, {48, 32}, {64, 16}, {80, 16}},
    {{64, 64}, {80, 64}, {64, 80}, {80, 80}},
    {{64, 64}, {80, 64}, {64, 16}, {80, 80}},
    {{64, 0}, {80, 64}, {64, 80}, {80, 80}},
    {{64, 0}, {80, 64}, {64, 16}, {80, 80}},
    {{32, 96}, {48, 96}, {32, 112}, {48, 112}},
    {{64, 0}, {48, 96}, {32, 112}, {48, 112}},
    {{32, 96}, {80, 0}, {32, 112}, {48, 112}},
    {{64, 0}, {80, 0}, {32, 112}, {48, 112}},
    {{0, 64}, {80, 64}, {0, 80}, {80, 80}},
    {{32, 32}, {48, 32}, {32, 112}, {48, 112}},
    {{0, 32}, {16, 32}, {0, 48}, {16, 48}},
    {{0, 32}, {16, 32}, {0, 48}, {80, 16}},
    {{64, 32}, {80, 32}, {64, 48}, {80, 48}},
    {{64, 32}, {80, 32}, {64, 16}, {80, 48}},
    {{64, 96}, {80, 96}, {64, 112}, {80, 112}},
    {{64, 0}, {80, 96}, {64, 112}, {80, 112}},
    {{0, 96}, {16, 96}, {0, 112}, {16, 112}},
    {{0, 96}, {80, 0}, {0, 112}, {16, 112}},
    {{0, 32}, {80, 32}, {0, 48}, {80, 48}},
    {{0, 32}, {16, 32}, {0, 112}, {16, 112}},
    {{0, 96}, {80, 96}, {0, 112}, {80, 112}},
    {{64, 32}, {80, 32}, {64, 112}, {80, 112}},
    {{0, 32}, {80, 32}, {0, 112}, {80, 112}},
    {{0, 0}, {16, 0}, {0, 16}, {16, 16}},
};

// Destination offsets of the four autotile quads within a 32x32 tile, in the
// table's TL, TR, BL, BR order.
static const int AUTOTILE_QUAD_OFF[4][2] = {{0, 0}, {16, 0}, {0, 16}, {16, 16}};

// One autotile animation frame is 96px wide (3 tiles); animated autotiles pack
// several such frames left to right.
static const int AUTOTILE_FRAME_W = 96;

// ---- RPG Maker VX / VX Ace tile geometry ----------------------------------
//
// VX replaced XP's single tileset + seven autotiles with nine sheets (A1-A5,
// B-E) and packed everything into one tile id space, which `RPG::Map#data`
// stores and `RPG::Tileset#flags` describes:
//
//   0..255 B, 256..511 C, 512..767 D, 768..1023 E   plain tiles
//   1536.. A5                                        plain tiles
//   2048.. A1 (water/waterfall), 2816.. A2 (ground),
//   4352.. A3 (buildings), 5888.. A4 (walls)         autotiles, 48 shapes each
//
// An autotile id encodes both *which* autotile (kind) and *which of the 48
// edge shapes* it is drawn as; each shape is four 16x16 quarter-tiles taken
// from the sheet at an offset that depends on the family. The three quad tables
// and the family offsets below are ported from the MIT-licensed RPG Maker MV
// corescript (rpgtkoolmv/corescript, js/rpg_core/Tilemap.js), which inherited
// VX Ace's tile system unchanged -- the same provenance as the RMXP quads
// above, which came from mkxp.
//
// The geometry is pure arithmetic, so it is also exposed to Ruby as
// Tilemap.vx_tile_quads and pinned by mruby-rgss/test (the drawing itself needs
// a display the test binary has not got).

// Tile id boundaries (Tilemap.TILE_ID_* in the corescript).
static const int VX_TILE_ID_A5 = 1536;
static const int VX_TILE_ID_A1 = 2048;
static const int VX_TILE_ID_A2 = 2816;
static const int VX_TILE_ID_A3 = 4352;
static const int VX_TILE_ID_A4 = 5888;
static const int VX_TILE_ID_MAX = 8192;

// Quarter-tile (column, row) of each of the four quads (TL, TR, BL, BR) making
// up one of the 48 floor shapes, in half-tile units from the autotile's origin.
static const int VX_FLOOR_QUADS[48][4][2] = {
    {{2, 4}, {1, 4}, {2, 3}, {1, 3}}, {{2, 0}, {1, 4}, {2, 3}, {1, 3}},
    {{2, 4}, {3, 0}, {2, 3}, {1, 3}}, {{2, 0}, {3, 0}, {2, 3}, {1, 3}},
    {{2, 4}, {1, 4}, {2, 3}, {3, 1}}, {{2, 0}, {1, 4}, {2, 3}, {3, 1}},
    {{2, 4}, {3, 0}, {2, 3}, {3, 1}}, {{2, 0}, {3, 0}, {2, 3}, {3, 1}},
    {{2, 4}, {1, 4}, {2, 1}, {1, 3}}, {{2, 0}, {1, 4}, {2, 1}, {1, 3}},
    {{2, 4}, {3, 0}, {2, 1}, {1, 3}}, {{2, 0}, {3, 0}, {2, 1}, {1, 3}},
    {{2, 4}, {1, 4}, {2, 1}, {3, 1}}, {{2, 0}, {1, 4}, {2, 1}, {3, 1}},
    {{2, 4}, {3, 0}, {2, 1}, {3, 1}}, {{2, 0}, {3, 0}, {2, 1}, {3, 1}},
    {{0, 4}, {1, 4}, {0, 3}, {1, 3}}, {{0, 4}, {3, 0}, {0, 3}, {1, 3}},
    {{0, 4}, {1, 4}, {0, 3}, {3, 1}}, {{0, 4}, {3, 0}, {0, 3}, {3, 1}},
    {{2, 2}, {1, 2}, {2, 3}, {1, 3}}, {{2, 2}, {1, 2}, {2, 3}, {3, 1}},
    {{2, 2}, {1, 2}, {2, 1}, {1, 3}}, {{2, 2}, {1, 2}, {2, 1}, {3, 1}},
    {{2, 4}, {3, 4}, {2, 3}, {3, 3}}, {{2, 4}, {3, 4}, {2, 1}, {3, 3}},
    {{2, 0}, {3, 4}, {2, 3}, {3, 3}}, {{2, 0}, {3, 4}, {2, 1}, {3, 3}},
    {{2, 4}, {1, 4}, {2, 5}, {1, 5}}, {{2, 0}, {1, 4}, {2, 5}, {1, 5}},
    {{2, 4}, {3, 0}, {2, 5}, {1, 5}}, {{2, 0}, {3, 0}, {2, 5}, {1, 5}},
    {{0, 4}, {3, 4}, {0, 3}, {3, 3}}, {{2, 2}, {1, 2}, {2, 5}, {1, 5}},
    {{0, 2}, {1, 2}, {0, 3}, {1, 3}}, {{0, 2}, {1, 2}, {0, 3}, {3, 1}},
    {{2, 2}, {3, 2}, {2, 3}, {3, 3}}, {{2, 2}, {3, 2}, {2, 1}, {3, 3}},
    {{2, 4}, {3, 4}, {2, 5}, {3, 5}}, {{2, 0}, {3, 4}, {2, 5}, {3, 5}},
    {{0, 4}, {1, 4}, {0, 5}, {1, 5}}, {{0, 4}, {3, 0}, {0, 5}, {1, 5}},
    {{0, 2}, {3, 2}, {0, 3}, {3, 3}}, {{0, 2}, {1, 2}, {0, 5}, {1, 5}},
    {{0, 4}, {3, 4}, {0, 5}, {3, 5}}, {{2, 2}, {3, 2}, {2, 5}, {3, 5}},
    {{0, 2}, {3, 2}, {0, 5}, {3, 5}}, {{0, 0}, {1, 0}, {0, 1}, {1, 1}},
};

// Walls (A3, and the odd rows of A4) have 16 shapes instead of 48.
static const int VX_WALL_QUADS[16][4][2] = {
    {{2, 2}, {1, 2}, {2, 1}, {1, 1}}, {{0, 2}, {1, 2}, {0, 1}, {1, 1}},
    {{2, 0}, {1, 0}, {2, 1}, {1, 1}}, {{0, 0}, {1, 0}, {0, 1}, {1, 1}},
    {{2, 2}, {3, 2}, {2, 1}, {3, 1}}, {{0, 2}, {3, 2}, {0, 1}, {3, 1}},
    {{2, 0}, {3, 0}, {2, 1}, {3, 1}}, {{0, 0}, {3, 0}, {0, 1}, {3, 1}},
    {{2, 2}, {1, 2}, {2, 3}, {1, 3}}, {{0, 2}, {1, 2}, {0, 3}, {1, 3}},
    {{2, 0}, {1, 0}, {2, 3}, {1, 3}}, {{0, 0}, {1, 0}, {0, 3}, {1, 3}},
    {{2, 2}, {3, 2}, {2, 3}, {3, 3}}, {{0, 2}, {3, 2}, {0, 3}, {3, 3}},
    {{2, 0}, {3, 0}, {2, 3}, {3, 3}}, {{0, 0}, {3, 0}, {0, 3}, {3, 3}},
};

// A waterfall (the odd A1 kinds) has 4.
static const int VX_WATERFALL_QUADS[4][4][2] = {
    {{2, 0}, {1, 0}, {2, 1}, {1, 1}},
    {{0, 0}, {1, 0}, {0, 1}, {1, 1}},
    {{2, 0}, {3, 0}, {2, 1}, {3, 1}},
    {{0, 0}, {3, 0}, {0, 1}, {3, 1}},
};

// One 16x16 piece (or, for a table tile's split quad, 16x8) of a VX tile: which
// sheet it comes from, where in that sheet, and where in the 32x32 destination
// tile it goes.
struct VXQuad {
  int sheet, sx, sy, dx, dy, w, h;
};

// Decode a VX / VX Ace tile id into the pieces that draw it, writing them to
// `out` (at most 8, for a table tile whose quads are split) and returning how
// many. `frame` animates A1 (water surface / waterfall); `table` is the A2
// "table" flag (RPG::Tileset#flags bit 0x80), which redraws the tile's middle
// rows from the counter row so a table/counter edge shows its side.
//
// Mirrors Tilemap#_drawNormalTile / #_drawAutotile in the MV corescript,
// including its "a shape outside the family's table draws nothing" behaviour
// (walls have 16 shapes and waterfalls 4, against the floor's 48).
int vx_tile_quads(int tile_id, int frame, bool table, VXQuad out[8]) {
  if (tile_id <= 0 || tile_id >= VX_TILE_ID_MAX)
    return 0;
  const int half = TILE_SIZE / 2;

  // Plain tiles: A5 is sheet 4, the B/C/D/E pages are sheets 5..8.
  if (tile_id < VX_TILE_ID_A1) {
    const int sheet = tile_id >= VX_TILE_ID_A5 ? 4 : 5 + tile_id / 256;
    // 1024..1535 fall past the E page and short of A5: no sheet holds them, and
    // the corescript draws nothing for such an id (its bitmaps[9] is
    // undefined).
    if (sheet > 8)
      return 0;
    const int sx = (tile_id / 128 % 2 * 8 + tile_id % 8) * TILE_SIZE;
    const int sy = (tile_id % 256 / 8 % 16) * TILE_SIZE;
    out[0] = VXQuad{sheet, sx, sy, 0, 0, TILE_SIZE, TILE_SIZE};
    return 1;
  }

  // Autotiles: the id carries both the autotile (kind) and one of the shapes.
  const int kind = (tile_id - VX_TILE_ID_A1) / 48;
  const int shape = (tile_id - VX_TILE_ID_A1) % 48;
  const int tx = kind % 8;
  const int ty = kind / 8;
  int sheet = 0, bx = 0, by = 0;
  const int (*quad_table)[4][2] = VX_FLOOR_QUADS;
  int shape_count = 48;
  bool is_table = false;

  if (tile_id < VX_TILE_ID_A2) {
    // A1: water surfaces animate over three frames in a 0,1,2,1 cycle, and the
    // odd kinds are waterfalls with their own three-frame cycle and table.
    static const int kWaterSurface[4] = {0, 1, 2, 1};
    const int surface = kWaterSurface[((frame % 4) + 4) % 4];
    sheet = 0;
    if (kind == 0) {
      bx = surface * 2;
      by = 0;
    } else if (kind == 1) {
      bx = surface * 2;
      by = 3;
    } else if (kind == 2) {
      bx = 6;
      by = 0;
    } else if (kind == 3) {
      bx = 6;
      by = 3;
    } else {
      bx = tx / 4 * 8;
      by = ty * 6 + tx / 2 % 2 * 3;
      if (kind % 2 == 0) {
        bx += surface * 2;
      } else {
        bx += 6;
        quad_table = VX_WATERFALL_QUADS;
        shape_count = 4;
        by += ((frame % 3) + 3) % 3;
      }
    }
  } else if (tile_id < VX_TILE_ID_A3) {
    sheet = 1;
    bx = tx * 2;
    by = (ty - 2) * 3;
    is_table = table;
  } else if (tile_id < VX_TILE_ID_A4) {
    sheet = 2;
    bx = tx * 2;
    by = (ty - 6) * 2;
    quad_table = VX_WALL_QUADS;
    shape_count = 16;
  } else {
    sheet = 3;
    bx = tx * 2;
    // A4 alternates ground rows (three half-tiles tall) and wall rows (two), so
    // the row offset advances by 2.5 with a half-row shift on the wall rows:
    // floor((ty - 10) * 2.5 + (ty odd ? 0.5 : 0)).
    by = ((ty - 10) * 5 + (ty % 2 == 1 ? 1 : 0)) / 2;
    if (ty % 2 == 1) {
      quad_table = VX_WALL_QUADS;
      shape_count = 16;
    }
  }

  if (shape >= shape_count)
    return 0;

  int n = 0;
  for (int i = 0; i < 4; ++i) {
    const int qsx = quad_table[shape][i][0];
    const int qsy = quad_table[shape][i][1];
    const int sx = (bx * 2 + qsx) * half;
    const int sy = (by * 2 + qsy) * half;
    const int dx = (i % 2) * half;
    const int dy = (i / 2) * half;
    if (is_table && (qsy == 1 || qsy == 5)) {
      // A table tile's middle rows come from the counter row, with the original
      // strip drawn over the bottom half so the edge reads as a side.
      static const int kTableX[4] = {0, 3, 2, 1};
      const int qsx2 = qsy == 1 ? kTableX[qsx % 4] : qsx;
      out[n++] = VXQuad{
          sheet, (bx * 2 + qsx2) * half, (by * 2 + 3) * half, dx, dy, half,
          half};
      out[n++] = VXQuad{sheet, sx, sy, dx, dy + half / 2, half, half / 2};
    } else {
      out[n++] = VXQuad{sheet, sx, sy, dx, dy, half, half};
    }
  }
  return n;
}

// A table (A2, `flags` bit 0x80) tile grows a short "leg" that spills 8px past
// its own 32x32 box into the map row below it -- RMXP/VX Ace's authentic
// table/counter look (a plain flat edge would stop dead at the tile boundary).
// Ported from mkxp's TileAtlasVX::readAutotileA2 (the real VX/VX Ace tile
// renderer, GPLv2 -- MV's corescript inherited the tile *geometry* from VX Ace
// unchanged, per the comment above vx_tile_quads, but drives this particular
// effect through a different, JS-only mechanism, so mkxp is the reference
// here instead).
//
// A leg exists on the bottom-left / bottom-right corner exactly when that
// corner would already trigger vx_tile_quads's own same-cell "counter row"
// substitution above (qsy == 1 or 5) -- confirmed by cross-checking every one
// of mkxp's 48 shapes' leg source coordinates against VX_FLOOR_QUADS: all 54
// legs across the 48 shapes matched that corner's own (unsubstituted) quad
// position exactly. So a leg's source is simply that corner's natural,
// non-substituted (sx, sy) -- the same value vx_tile_quads's substitution
// branch already computes and calls sx/sy there -- redrawn 16x16 (not the
// substitution's 16x8 strip) at dy = TILE_SIZE - half/2, which lands its top
// 8px over the tile's own bottom edge and its bottom 8px one map row down.
//
// Unlike MV's neighbour-examining _drawTableEdge, this needs no lookup of the
// tile below: mkxp draws every table tile's leg unconditionally (no
// suppression when the tile below is itself a table), so the leg is a pure
// function of the owning tile's own id. The caller (tilemap_refresh_vx) must
// still draw legs in a pass that runs after every plain tile of the same
// layer, or a tile in the row below would be painted back over the leg.
int vx_table_leg_quads(int tile_id, VXQuad out[2]) {
  if (tile_id < VX_TILE_ID_A2 || tile_id >= VX_TILE_ID_A3)
    return 0;
  const int half = TILE_SIZE / 2;
  const int kind = (tile_id - VX_TILE_ID_A1) / 48;
  const int shape = (tile_id - VX_TILE_ID_A1) % 48;
  if (shape >= 48)
    return 0;
  const int tx = kind % 8, ty = kind / 8;
  const int bx = tx * 2, by = (ty - 2) * 3;
  static const int kCorner[2] = {2, 3};  // BL, BR -- VX_FLOOR_QUADS index
  int n = 0;
  for (int c = 0; c < 2; ++c) {
    const int qsx = VX_FLOOR_QUADS[shape][kCorner[c]][0];
    const int qsy = VX_FLOOR_QUADS[shape][kCorner[c]][1];
    if (qsy != 1 && qsy != 5)
      continue;
    const int sx = (bx * 2 + qsx) * half;
    const int sy = (by * 2 + qsy) * half;
    const int dx = c == 0 ? 0 : half;
    out[n++] = VXQuad{/*sheet=*/1,          sx,   sy,  dx,
                      TILE_SIZE - half / 2, half, half};
  }
  return n;
}

// z of the priority "above" layer (see the split in tilemap_refresh). INTERIM:
// a single flat layer above the characters is only an approximation of RMXP's
// per-row priority interleaving — it puts *every* priority tile above *every*
// character, rather than only the ones on lower rows.
//
// The z formula is no longer a guess: RMXP's own Game_Character#screen_z
// (read out of the test bed's Scripts.rxdata) is
//
//     z = (real_y - display_y + 3) / 4 + 32          // the on-screen pixel y
//     z += priorities[tile_id] * 32                  // ... for a tile
//
// so a character's z *is* its screen y, and a priority-n tile sorts as though
// it stood n rows lower. In map units that is (ty + prio) * 32 + 32 - oy, which
// is what a per-row strip must use; @always_on_top returns 999, the ceiling
// those strips have to stay under.
//
// The constant below is the interim stand-in: above stock character sprites
// (z ~ screen_y, up to ~512) but below the fog/weather planes (z ~ 1000/3000),
// and below the 999 an always-on-top character claims.
static const mrb_int TILEMAP_ABOVE_Z = 900;

// RMXP priorities run 1..5, so the bucket a priority tile sorts into --
// `ty + prio`, per the formula above -- can be reached from any of five map
// rows: bucket B holds every tile with `ty = B - prio`, i.e. rows B-5..B-1.
// A strip is therefore five tile rows tall, positioned at (B-5)*TILE_SIZE - oy,
// and a tile of priority p lands at local row (5 - p) inside it -- which
// depends only on the priority, not on the row it came from.
//
// Sizing this correctly matters: a full-screen canvas per bucket would be
// 1.17 MiB x 21 = 24.6 MiB for one map, and a one-row strip cannot hold a
// bucket at all.
static const int TILEMAP_PRIO_SPAN = 5;

// Strips are pooled by `bucket % TILEMAP_STRIP_SLOTS` rather than by the bucket
// itself, which is what keeps the set bounded on a tall map. Keyed on the
// absolute bucket, walking down a 200-row map would allocate a strip per row
// and never let one go -- 200 x 400 KiB of canvases for a map only ever showing
// twenty of them.
//
// The modulus has to exceed the number of buckets that can be visible at once,
// or two live buckets would collide in one slot: a viewport shows at most
// (height / TILE_SIZE) + 1 rows, and a bucket reaches TILEMAP_PRIO_SPAN rows
// further down, so 16 + 5 = 21 for XP's 480px viewport. 24 leaves headroom
// without materially raising the ceiling, since no more than 21 slots can be
// occupied at a time whatever the modulus.
static const int TILEMAP_STRIP_SLOTS = 24;

// Fetch (creating on first use) the canvas strip for priority bucket `b`.
//
// Strips live in @_tm_strips, an mruby Hash keyed by bucket, so the GC keeps
// them alive and tilemap_dispose can walk them. Allocation is lazy and per
// bucket: a map with no priority tiles allocates nothing, and a tileset using
// only priority 1 allocates one strip per occupied row rather than 21.
//
// Each strip is a z-ordered companion object registered the same way a Sprite
// is (wrap pattern + register_zobj), so gfx_update's shared z sort interleaves
// it with the character sprites that share the viewport -- which is the whole
// point of the exercise.
Bitmap* tilemap_strip(mrb_state* M, mrb_value self, int b, int w) {
  mrb_value strips = mrb_iv_get(M, self, MRB_IVSYM(_tm_strips));
  if (!mrb_hash_p(strips)) {
    strips = mrb_hash_new(M);
    mrb_iv_set(M, self, MRB_IVSYM(_tm_strips), strips);
  }
  const int slot =
      ((b % TILEMAP_STRIP_SLOTS) + TILEMAP_STRIP_SLOTS) % TILEMAP_STRIP_SLOTS;
  const mrb_value key = mrb_fixnum_value(slot);
  const mrb_value found = mrb_hash_get(M, strips, key);
  if (mrb_test(found) && display_node(found)) {
    // The slot may have been holding a different bucket before the map
    // scrolled; it is reused in place rather than reallocated, so record which
    // bucket it carries now for the placement pass.
    mrb_iv_set(M, found, MRB_IVSYM(_bucket), mrb_fixnum_value(b));
    return &DataType<Bitmap>::get(M, mrb_iv_get(M, found, MRB_IVSYM(_bitmap)));
  }
  if (w <= 0)
    return nullptr;
  // Everything below allocates; keep it out of the GC's way until the strip is
  // reachable from the hash.
  const int arena = mrb_gc_arena_save(M);
  const mrb_value vp = mrb_iv_get(M, self, MRB_IVSYM(viewport));
  const int h = TILEMAP_PRIO_SPAN * TILE_SIZE;
  const mrb_value obj = mrb_obj_value(
      mrb_data_object_alloc(M, mrb_obj_class(M, self), nullptr, nullptr));
  display_init(M, obj, &tilemap_part_type);
  gfx::Node* c = gfx::sprite_new(parent_object(M, vp));
  gfx::node_set_pos(c, 0, 0);
  wrap_node(M, obj, c);
  register_zobj(M, obj);
  RClass* bmp_class = mrb_class_get_under_id(
      M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Bitmap));
  const mrb_value bmp_v =
      DataType<Bitmap>::make(M, bmp_class, w, h, kPixelARGB8888);
  Bitmap& bmp = DataType<Bitmap>::get(M, bmp_v);
  std::fill(bmp.buffer.begin(), bmp.buffer.end(), static_cast<uint8_t>(0));
  gfx::sprite_set_pixels(c, bmp.buffer.data(), w, h, kPixelARGB8888);
  mrb_iv_set(M, obj, MRB_IVSYM(_bitmap), bmp_v);
  mrb_iv_set(M, obj, MRB_IVSYM(_bucket), mrb_fixnum_value(b));
  mrb_hash_set(M, strips, key, obj);
  mrb_gc_arena_restore(M, arena);
  return &bmp;
}

// Every strip currently allocated, as [bucket, obj] pairs. Empty before the
// first priority tile is drawn.
using TilemapStrip = std::pair<int, mrb_value>;

std::vector<TilemapStrip> tilemap_strips(mrb_state* M, mrb_value self) {
  std::vector<TilemapStrip> out;
  const mrb_value strips = mrb_iv_get(M, self, MRB_IVSYM(_tm_strips));
  if (!mrb_hash_p(strips))
    return out;
  const mrb_value keys = mrb_hash_keys(M, strips);
  for (mrb_int i = 0; i < ary_size(keys); ++i) {
    const mrb_value k = mrb_ary_ref(M, keys, i);
    const mrb_value v = mrb_hash_get(M, strips, k);
    if (!mrb_test(v) || !display_node(v))
      continue;
    // The bucket the slot currently carries, which is what its position and z
    // are derived from -- not the slot index the hash is keyed by.
    const mrb_value b = mrb_iv_get(M, v, MRB_IVSYM(_bucket));
    out.push_back({mrb_test(b) ? static_cast<int>(mrb_as_int(M, b)) : 0, v});
  }
  return out;
}

// Redraw the visible part of the map. For each of the three map-data layers,
// the tiles overlapping the viewport (given ox/oy) are blitted from the tileset
// (regular tiles, id >= 384) or assembled from the four autotile quads (id
// 48..383), with autotile animation. Priority-0 tiles draw into the ground
// canvas; priority >= 1 tiles (from the `priorities` table) draw into the
// separate "above" canvas that sorts over the characters (see TILEMAP_ABOVE_Z).
// Both canvases are invalidated directly (their buffers are not sprite @bitmaps
// that Graphics.update's dirty sweep watches).
// Whether a tilemap has been handed any of the nine VX / VX Ace sheets, which
// is what tells the two tile models apart at draw time.
bool vx_has_sheets(mrb_state* M, mrb_value bitmaps) {
  if (!mrb_array_p(bitmaps))
    return false;
  for (mrb_int i = 0; i < ary_size(bitmaps); ++i) {
    const mrb_value b = mrb_ary_ref(M, bitmaps, i);
    if (mrb_test(b) && DATA_PTR(b))
      return true;
  }
  return false;
}

// Draw a VX / VX Ace map into the ground (and priority "above") canvases.
// Returns whether the visible area holds an animated tile, so tilemap_update
// can skip the periodic re-tile on a static map.
//
// The three tile layers of `map_data` are drawn bottom-up. `RPG::Tileset#flags`
// carries the per-tile bits: 0x10 routes a tile to the above layer (MV's
// `_isHigherTile`) and 0x80 marks an A2 "table" tile, whose middle rows are
// redrawn from the counter row.
bool tilemap_refresh_vx(mrb_state* M,
                        mrb_value self,
                        Bitmap& dst,
                        Bitmap* above,
                        mrb_value bitmaps,
                        mrb_value md_v,
                        mrb_int ox,
                        mrb_int oy,
                        int anim) {
  Table& md = DataType<Table>::get(M, md_v);
  const mrb_value flags_v = mrb_iv_get(M, self, MRB_IVSYM(flags));
  Table* flags = (mrb_test(flags_v) && DATA_PTR(flags_v))
                     ? &DataType<Table>::get(M, flags_v)
                     : nullptr;

  const int mapw = md.xsize, maph = md.ysize;
  // Layer 3 of a VX Ace map holds region ids, which are not drawn.
  const int layers = md.zsize < 3 ? md.zsize : 3;
  // MV advances the tile animation every 30 ticks; ours counts frames the same
  // way the XP path does.
  const int frame = anim / 30;
  bool animated = false;

  int tx0 = static_cast<int>(ox) / TILE_SIZE;
  int ty0 = static_cast<int>(oy) / TILE_SIZE;
  if (tx0 < 0)
    tx0 = 0;
  if (ty0 < 0)
    ty0 = 0;
  int tx1 = static_cast<int>(ox + dst.width) / TILE_SIZE + 1;
  int ty1 = static_cast<int>(oy + dst.height) / TILE_SIZE + 1;
  if (tx1 > mapw)
    tx1 = mapw;
  if (ty1 > maph)
    ty1 = maph;

  VXQuad quads[8];
  for (int layer = 0; layer < layers; ++layer) {
    for (int ty = ty0; ty < ty1; ++ty) {
      for (int tx = tx0; tx < tx1; ++tx) {
        const int idx = tx + ty * mapw + layer * mapw * maph;
        if (idx < 0 || idx >= static_cast<int>(md.data.size()))
          continue;
        const int id = md.data[idx];
        if (id <= 0)
          continue;
        const int flag =
            (flags && id >= 0 && id < static_cast<int>(flags->data.size()))
                ? flags->data[id]
                : 0;
        const bool is_table =
            id >= VX_TILE_ID_A2 && id < VX_TILE_ID_A3 && (flag & 0x80) != 0;
        const int n = vx_tile_quads(id, frame, is_table, quads);
        if (n == 0)
          continue;
        // The A1 page (water and waterfalls) is the animated one.
        if (id >= VX_TILE_ID_A1 && id < VX_TILE_ID_A2)
          animated = true;

        Bitmap& target = ((flag & 0x10) != 0 && above) ? *above : dst;
        const int dx0 = tx * TILE_SIZE - static_cast<int>(ox);
        const int dy0 = ty * TILE_SIZE - static_cast<int>(oy);
        for (int q = 0; q < n; ++q) {
          const VXQuad& v = quads[q];
          const mrb_value sheet_v = mrb_ary_ref(M, bitmaps, v.sheet);
          if (!mrb_test(sheet_v) || !DATA_PTR(sheet_v))
            continue;
          Bitmap& sheet = DataType<Bitmap>::get(M, sheet_v);
          blit_blend(target, dx0 + v.dx, dy0 + v.dy, sheet, v.sx, v.sy, v.w,
                     v.h);
        }
      }
    }

    // Table legs, in a pass of their own after every plain tile of this layer
    // is down: a leg spills into the row below, so it must draw after that
    // row's own tile or the leg would be painted straight back over (see
    // vx_table_leg_quads).
    VXQuad legs[2];
    for (int ty = ty0; ty < ty1; ++ty) {
      for (int tx = tx0; tx < tx1; ++tx) {
        const int idx = tx + ty * mapw + layer * mapw * maph;
        if (idx < 0 || idx >= static_cast<int>(md.data.size()))
          continue;
        const int id = md.data[idx];
        if (id < VX_TILE_ID_A2 || id >= VX_TILE_ID_A3 || !flags ||
            id >= static_cast<int>(flags->data.size()))
          continue;
        const int flag = flags->data[id];
        if ((flag & 0x80) == 0)
          continue;
        const int n = vx_table_leg_quads(id, legs);
        if (n == 0)
          continue;
        Bitmap& target = ((flag & 0x10) != 0 && above) ? *above : dst;
        const int dx0 = tx * TILE_SIZE - static_cast<int>(ox);
        const int dy0 = ty * TILE_SIZE - static_cast<int>(oy);
        for (int q = 0; q < n; ++q) {
          const VXQuad& v = legs[q];
          const mrb_value sheet_v = mrb_ary_ref(M, bitmaps, v.sheet);
          if (!mrb_test(sheet_v) || !DATA_PTR(sheet_v))
            continue;
          Bitmap& sheet = DataType<Bitmap>::get(M, sheet_v);
          blit_blend(target, dx0 + v.dx, dy0 + v.dy, sheet, v.sx, v.sy, v.w,
                     v.h);
        }
      }
    }
  }
  return animated;
}

// Tint the tilemap's composed canvases with its viewport's tone. The map has no
// tone of its own, so this is purely the viewport's -- and it has to happen
// here rather than per source tile, because a tone rescales the *drawn* result.
// Both the ground canvas and the priority "above" canvas are covered, so a
// tinted map tints its roofs too.
void tilemap_apply_viewport_tone(mrb_state* M,
                                 mrb_value self,
                                 Bitmap& dst,
                                 Bitmap* above) {
  const Tone tn = viewport_tone(M, mrb_iv_get(M, self, MRB_IVSYM(viewport)));
  if (!tone_is_set(tn))
    return;
  Bitmap* targets[2] = {&dst, above};
  for (Bitmap* t : targets) {
    if (!t)
      continue;
    for (int y = 0; y < t->height; ++y) {
      for (int x = 0; x < t->width; ++x) {
        int r, g, b, a;
        bmp_read(*t, x, y, r, g, b, a);
        if (a == 0)
          continue;
        apply_tone_px(r, g, b, tn);
        bmp_put(*t, x, y, r, g, b, a);
      }
    }
    t->dirty = true;
  }
}

// Lazily create the priority "above" layer the first time it is actually
// needed. Before the per-row scheme (TILEMAP_PRIO_SPAN below), this
// flat companion canvas was the *only* place a priority tile could draw, so
// tilemap_init created it unconditionally for every Tilemap. Now only
// tilemap_refresh_vx (the VX/VX Ace tile model, which still uses this flat
// "above characters" layer)
// ever draws into it; XP's own priorities route through the per-row strips
// exclusively and never touch this canvas at all. Left eagerly allocated
// anyway, every XP tilemap paid a permanent, always-blank 1.17 MiB canvas (at
// XP's 640x480) plus a wasted per-refresh viewport-tone pass walking every
// one of its pixels (tilemap_apply_viewport_tone) for a layer that could
// never show anything -- dead weight on every RPG Maker XP game, including
// the psp/wio targets this code is shared with (see TILEMAP_STRIP_SLOTS's own
// comment on why that budget matters here). Mirrors tilemap_strip's own lazy
// shape: created once, held on the tilemap so the GC keeps it alive, torn
// down by tilemap_dispose exactly as before.
void tilemap_ensure_above(mrb_state* M, mrb_value self, int w, int h) {
  const mrb_value existing = mrb_iv_get(M, self, MRB_IVSYM(_tm_above_obj));
  if (mrb_test(existing) && display_node(existing))
    return;

  const mrb_value vp = mrb_iv_get(M, self, MRB_IVSYM(viewport));
  const mrb_value above_obj = mrb_obj_value(
      mrb_data_object_alloc(M, mrb_obj_class(M, self), nullptr, nullptr));
  display_init(M, above_obj, &tilemap_part_type);
  gfx::Node* ac = gfx::sprite_new(parent_object(M, vp));
  gfx::node_set_pos(ac, 0, 0);
  wrap_node(M, above_obj, ac);
  register_zobj(M, above_obj);
  // Sync to whatever this tilemap's own z/visible already are, rather than
  // the fixed z=TILEMAP_ABOVE_Z/always-visible the old eager tilemap_init
  // call hardcoded: that always ran before a script had any chance to touch
  // either, so it was trivially right by construction, but a lazy create can
  // now run well after a script has already set `z=`/`visible=` on the
  // tilemap (its first VX-path refresh, not its construction).
  const mrb_value self_z = mrb_iv_get(M, self, MRB_IVSYM(z));
  const mrb_int z = mrb_test(self_z) ? mrb_as_int(M, self_z) : 0;
  mrb_iv_set(M, above_obj, MRB_IVSYM(z), mrb_fixnum_value(z + TILEMAP_ABOVE_Z));
  const mrb_value self_visible = mrb_iv_get(M, self, MRB_IVSYM(visible));
  if (!mrb_nil_p(self_visible) && !mrb_test(self_visible))
    gfx::node_set_hidden(ac, true);
  update_z(M);

  RClass* bmp_class = mrb_class_get_under_id(
      M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Bitmap));
  const mrb_value above_canvas_v =
      DataType<Bitmap>::make(M, bmp_class, w, h, kPixelARGB8888);
  Bitmap& above_canvas = DataType<Bitmap>::get(M, above_canvas_v);
  std::fill(above_canvas.buffer.begin(), above_canvas.buffer.end(),
            static_cast<uint8_t>(0));
  gfx::sprite_set_pixels(ac, above_canvas.buffer.data(), w, h, kPixelARGB8888);
  mrb_iv_set(M, self, MRB_IVSYM(_tm_above_obj), above_obj);
  mrb_iv_set(M, self, MRB_IVSYM(_tm_above_canvas), above_canvas_v);
}

void tilemap_refresh(mrb_state* M, mrb_value self) {
  gfx::Node* obj = display_node(self);
  if (!obj)
    return;
  const mrb_value canvas_v = mrb_iv_get(M, self, MRB_IVSYM(_tm_canvas));
  if (mrb_nil_p(canvas_v))
    return;
  Bitmap& dst = DataType<Bitmap>::get(M, canvas_v);
  std::fill(dst.buffer.begin(), dst.buffer.end(), static_cast<uint8_t>(0));

  const mrb_value ts_v = mrb_iv_get(M, self, MRB_IVSYM(tileset));
  const mrb_value md_v = mrb_iv_get(M, self, MRB_IVSYM(map_data));

  // RPG Maker VX / VX Ace address their nine sheets through `bitmaps` instead
  // of XP's single `tileset` + `autotiles`, and describe each tile with the
  // `flags` table rather than `priorities`. A tilemap that has been given any
  // sheet is drawn the VX way; everything below stays the XP path.
  const mrb_value bmps_v = mrb_iv_get(M, self, MRB_IVSYM(bitmaps));
  const bool is_vx =
      vx_has_sheets(M, bmps_v) && mrb_test(md_v) && DATA_PTR(md_v);

  // The priority "above" canvas and its LVGL object, so priority tiles can be
  // routed to it and it can be invalidated alongside the ground canvas -- see
  // tilemap_ensure_above's own comment for why this is only ever created for
  // the VX path.
  if (is_vx)
    tilemap_ensure_above(M, self, dst.width, dst.height);
  const mrb_value above_v = mrb_iv_get(M, self, MRB_IVSYM(_tm_above_canvas));
  Bitmap* above = (mrb_test(above_v) && DATA_PTR(above_v))
                      ? &DataType<Bitmap>::get(M, above_v)
                      : nullptr;
  if (above)
    std::fill(above->buffer.begin(), above->buffer.end(),
              static_cast<uint8_t>(0));
  const mrb_value above_obj_v = mrb_iv_get(M, self, MRB_IVSYM(_tm_above_obj));
  gfx::Node* above_lv =
      mrb_test(above_obj_v) ? display_node(above_obj_v) : nullptr;

  // Per-tile priority table (0..5 per tile id); tiles with priority >= 1 draw
  // into the above layer. A nil or short table leaves everything at priority 0.
  const mrb_value pr_v = mrb_iv_get(M, self, MRB_IVSYM(priorities));
  Table* pr = (mrb_test(pr_v) && DATA_PTR(pr_v))
                  ? &DataType<Table>::get(M, pr_v)
                  : nullptr;

  if (is_vx) {
    const mrb_value anim_v = mrb_iv_get(M, self, MRB_IVSYM(_tm_anim));
    const bool animated =
        tilemap_refresh_vx(M, self, dst, above, bmps_v, md_v,
                           mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(ox))),
                           mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(oy))),
                           mrb_test(anim_v) ? mrb_as_int(M, anim_v) : 0);
    mrb_iv_set(M, self, MRB_IVSYM(_tm_animated), mrb_bool_value(animated));
    tilemap_apply_viewport_tone(M, self, dst, above);
    dst.dirty = true;
    if (above)
      above->dirty = true;
    gfx::node_invalidate(obj);
    if (above_lv)
      gfx::node_invalidate(above_lv);
    return;
  }

  if (!mrb_test(ts_v) || !DATA_PTR(ts_v) || !mrb_test(md_v) ||
      !DATA_PTR(md_v)) {
    gfx::node_invalidate(obj);
    if (above_lv)
      gfx::node_invalidate(above_lv);
    return;
  }
  Bitmap& ts = DataType<Bitmap>::get(M, ts_v);
  Table& md = DataType<Table>::get(M, md_v);
  const int cols = ts.width >= TILE_SIZE ? ts.width / TILE_SIZE : TILESET_COLS;
  const int mapw = md.xsize, maph = md.ysize;
  const int layers = md.zsize < 3 ? md.zsize : 3;
  const mrb_int ox = mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(ox)));
  const mrb_int oy = mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(oy)));
  const mrb_value autotiles_v = mrb_iv_get(M, self, MRB_IVSYM(autotiles));
  const bool have_autotiles = mrb_array_p(autotiles_v);

  // Autotile animation: an autotile bitmap wider than one 96px frame holds
  // several animation frames side by side. RMXP shows each of the four frames
  // for 16 ticks (mkxp's atAnimation table), so the current frame is the tick
  // counter / 16, mod 4. `any_anim` records whether this map actually has an
  // animated autotile, so tilemap_update can skip the periodic re-tile when the
  // map is static.
  const mrb_value anim_v = mrb_iv_get(M, self, MRB_IVSYM(_tm_anim));
  const int anim = mrb_test(anim_v) ? mrb_as_int(M, anim_v) : 0;
  const int frame_idx = (anim / 16) % 4;
  bool any_anim = false;

  // Buckets that received a tile this frame. A strip that misses out is hidden
  // rather than freed, so scrolling back does not reallocate it.
  std::vector<int> used_buckets;
  for (const auto& e : tilemap_strips(M, self)) {
    Bitmap& b =
        DataType<Bitmap>::get(M, mrb_iv_get(M, e.second, MRB_IVSYM(_bitmap)));
    std::fill(b.buffer.begin(), b.buffer.end(), static_cast<uint8_t>(0));
  }

  int tx0 = static_cast<int>(ox) / TILE_SIZE;
  int ty0 = static_cast<int>(oy) / TILE_SIZE;
  if (tx0 < 0)
    tx0 = 0;
  if (ty0 < 0)
    ty0 = 0;
  int tx1 = static_cast<int>(ox + dst.width) / TILE_SIZE + 1;
  int ty1 = static_cast<int>(oy + dst.height) / TILE_SIZE + 1;
  if (tx1 > mapw)
    tx1 = mapw;
  if (ty1 > maph)
    ty1 = maph;

  for (int layer = 0; layer < layers; ++layer) {
    for (int ty = ty0; ty < ty1; ++ty) {
      for (int tx = tx0; tx < tx1; ++tx) {
        const int idx = tx + ty * mapw + layer * mapw * maph;
        if (idx < 0 || idx >= static_cast<int>(md.data.size()))
          continue;
        const int id = md.data[idx];
        if (id < 48)  // 0 = empty; 1..47 are the unused blank autotile
          continue;
        const int dx0 = tx * TILE_SIZE - static_cast<int>(ox);
        int dy0 = ty * TILE_SIZE - static_cast<int>(oy);
        // Priority 0 -> ground canvas. Priority 1..5 -> the strip for bucket
        // ty + prio, where it sits at local row (SPAN - prio); the strip itself
        // is placed and z-sorted below, once the whole map has been walked. An
        // out-of-range id or nil table means priority 0, and a priority beyond
        // the 1..5 the editor offers falls back to the ground rather than
        // indexing off the end of a strip.
        const int prio =
            (pr && id >= 0 && id < static_cast<int>(pr->data.size()))
                ? pr->data[id]
                : 0;
        Bitmap* target_p = &dst;
        if (prio >= 1 && prio <= TILEMAP_PRIO_SPAN) {
          const int bucket = ty + prio;
          if (Bitmap* strip = tilemap_strip(M, self, bucket, dst.width)) {
            target_p = strip;
            dy0 = (TILEMAP_PRIO_SPAN - prio) * TILE_SIZE;
            if (std::find(used_buckets.begin(), used_buckets.end(), bucket) ==
                used_buckets.end())
              used_buckets.push_back(bucket);
          }
        }
        Bitmap& target = *target_p;
        if (id < 384) {
          // Autotile: id/48 selects autotiles[0..6], id%48 the 48-shape quad
          // assembly. Uses the first animation frame (x offset 0).
          if (!have_autotiles)
            continue;
          const mrb_value at = mrb_ary_ref(M, autotiles_v, id / 48 - 1);
          if (!mrb_test(at) || !DATA_PTR(at))
            continue;
          Bitmap& ab = DataType<Bitmap>::get(M, at);
          const int shape = id % 48;
          // Animated autotile: shift the source into the current frame's 96px
          // column. A single-frame (96px-wide) autotile stays at offset 0.
          int sx_off = 0;
          if (ab.width > AUTOTILE_FRAME_W) {
            any_anim = true;
            sx_off =
                (frame_idx % (ab.width / AUTOTILE_FRAME_W)) * AUTOTILE_FRAME_W;
          }
          for (int q = 0; q < 4; ++q)
            blit_blend(target, dx0 + AUTOTILE_QUAD_OFF[q][0],
                       dy0 + AUTOTILE_QUAD_OFF[q][1], ab,
                       AUTOTILE_QUADS[shape][q][0] + sx_off,
                       AUTOTILE_QUADS[shape][q][1], 16, 16);
        } else {
          // Regular tile from the tileset.
          const int ti = id - 384;
          blit_blend(target, dx0, dy0, ts, (ti % cols) * TILE_SIZE,
                     (ti / cols) * TILE_SIZE, TILE_SIZE, TILE_SIZE);
        }
      }
    }
  }
  mrb_iv_set(M, self, MRB_IVSYM(_tm_animated), mrb_bool_value(any_anim));
  tilemap_apply_viewport_tone(M, self, dst, above);

  // Place every strip and give it the z its bucket sorts at. Both depend on oy,
  // so both are refreshed here rather than once at creation -- this runs on
  // every scroll, which is exactly when they move.
  const Tone strip_tone =
      viewport_tone(M, mrb_iv_get(M, self, MRB_IVSYM(viewport)));
  for (const auto& e : tilemap_strips(M, self)) {
    gfx::Node* sc = display_node(e.second);
    if (!sc)
      continue;
    const bool used = std::find(used_buckets.begin(), used_buckets.end(),
                                e.first) != used_buckets.end();
    if (!used) {
      gfx::node_set_hidden(sc, true);
      continue;
    }
    gfx::node_set_hidden(sc, false);
    const int top_row = e.first - TILEMAP_PRIO_SPAN;
    gfx::node_set_pos(sc, 0, top_row * TILE_SIZE - static_cast<int>(oy));
    mrb_iv_set(M, e.second, MRB_IVSYM(z),
               mrb_fixnum_value(e.first * TILE_SIZE + TILE_SIZE -
                                static_cast<mrb_int>(oy)));
    Bitmap& sb =
        DataType<Bitmap>::get(M, mrb_iv_get(M, e.second, MRB_IVSYM(_bitmap)));
    if (tone_is_set(strip_tone)) {
      for (int y = 0; y < sb.height; ++y) {
        for (int x = 0; x < sb.width; ++x) {
          int r, g, bl, a;
          bmp_read(sb, x, y, r, g, bl, a);
          if (a == 0)
            continue;
          apply_tone_px(r, g, bl, strip_tone);
          bmp_put(sb, x, y, r, g, bl, a);
        }
      }
    }
    sb.dirty = true;
    gfx::node_invalidate(sc);
  }
  if (!used_buckets.empty())
    update_z(M);

  if (above)
    above->dirty = true;
  gfx::node_invalidate(obj);
  if (above_lv)
    gfx::node_invalidate(above_lv);
}

mrb_value tilemap_init(mrb_state* M, mrb_value self) {
  mrb_value vp = mrb_nil_value();
  mrb_get_args(M, "|o", &vp);

  mrb_int w = 0, h = 0;
  if (mrb_nil_p(vp)) {
    int32_t dw, dh;
    gfx::display_size(get_display(M), dw, dh);
    w = dw;
    h = dh;
  } else {
    Rect& r = DataType<Rect>::get(M, mrb_iv_get(M, vp, MRB_IVSYM(rect)));
    w = r.width;
    h = r.height;
  }
  if (w <= 0)
    w = 1;
  if (h <= 0)
    h = 1;

  display_init(M, self, &tilemap_type);
  gfx::Node* c = gfx::sprite_new(parent_object(M, vp));
  wrap_node(M, self, c);
  register_zobj(M, self);
  gfx::node_set_pos(c, 0, 0);

  RClass* bmp_class = mrb_class_get_under_id(
      M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Bitmap));
  const mrb_value canvas_v =
      DataType<Bitmap>::make(M, bmp_class, w, h, kPixelARGB8888);
  Bitmap& canvas = DataType<Bitmap>::get(M, canvas_v);
  std::fill(canvas.buffer.begin(), canvas.buffer.end(),
            static_cast<uint8_t>(0));
  gfx::sprite_set_pixels(c, canvas.buffer.data(), w, h, kPixelARGB8888);

  mrb_iv_set(M, self, MRB_IVSYM(_tm_canvas), canvas_v);
  mrb_iv_set(M, self, MRB_IVSYM(viewport), vp);
  mrb_iv_set(M, self, MRB_IVSYM(tileset), mrb_nil_value());
  mrb_iv_set(M, self, MRB_IVSYM(map_data), mrb_nil_value());
  mrb_iv_set(M, self, MRB_IVSYM(ox), mrb_fixnum_value(0));
  mrb_iv_set(M, self, MRB_IVSYM(oy), mrb_fixnum_value(0));
  mrb_iv_set(M, self, MRB_IVSYM(_tm_anim), mrb_fixnum_value(0));

  // Priority "above" layer: no longer created here. It is only ever drawn
  // into by the VX/VX Ace tile model, so it is now allocated lazily on the
  // first VX-path refresh instead -- see tilemap_ensure_above's own comment.
  return self;
}

// Tearing down the tilemap also tears down its companion "above" canvas (a
// separate LVGL object that obj_dispose on the tilemap would otherwise leave
// on screen and in the z-order set).
mrb_value tilemap_dispose(mrb_state* M, mrb_value self) {
  const mrb_value above = mrb_iv_get(M, self, MRB_IVSYM(_tm_above_obj));
  if (mrb_test(above) && display_node(above))
    obj_dispose(M, above);
  // Each priority strip is its own LVGL object in the z set; disposing the
  // tilemap alone would leave them on screen and sorting.
  for (const auto& e : tilemap_strips(M, self))
    obj_dispose(M, e.second);
  mrb_iv_set(M, self, MRB_IVSYM(_tm_strips), mrb_nil_value());
  return obj_dispose(M, self);
}

// Per-frame tick: advance the autotile animation. The counter cycles 0..63 and
// the frame it selects is counter / 16, so only every 16th update crosses a
// frame boundary and needs a re-tile — and only when the map has an animated
// autotile at all (recorded by tilemap_refresh). A static map does no work.
mrb_value tilemap_update(mrb_state* M, mrb_value self) {
  if (!mrb_test(mrb_iv_get(M, self, MRB_IVSYM(_tm_animated))))
    return self;
  const mrb_value anim_v = mrb_iv_get(M, self, MRB_IVSYM(_tm_anim));
  const int anim = mrb_test(anim_v) ? mrb_as_int(M, anim_v) : 0;
  const int next = (anim + 1) % 64;
  mrb_iv_set(M, self, MRB_IVSYM(_tm_anim), mrb_fixnum_value(next));
  if (anim / 16 != next / 16)
    tilemap_refresh(M, self);
  return self;
}

mrb_value tilemap_set_tileset_native_body(mrb_state* M,
                                          mrb_value self,
                                          mrb_value v) {
  mrb_iv_set(M, self, MRB_IVSYM(tileset), v);
  tilemap_refresh(M, self);
  return v;
}

mrb_value tilemap_set_tileset(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  return tilemap_set_tileset_native_body(M, self, v);
}

mrb_value tilemap_set_map_data_native_body(mrb_state* M,
                                           mrb_value self,
                                           mrb_value v) {
  mrb_iv_set(M, self, MRB_IVSYM(map_data), v);
  tilemap_refresh(M, self);
  return v;
}

mrb_value tilemap_set_map_data(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  return tilemap_set_map_data_native_body(M, self, v);
}

// Native so assigning the priority table (usually right after map_data=)
// re-renders the ground/above split. A plain attr_writer would not.
mrb_value tilemap_set_priorities_native_body(mrb_state* M,
                                             mrb_value self,
                                             mrb_value v) {
  mrb_iv_set(M, self, MRB_IVSYM(priorities), v);
  tilemap_refresh(M, self);
  return v;
}

mrb_value tilemap_set_priorities(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  return tilemap_set_priorities_native_body(M, self, v);
}

// RGSS2/RGSS3 `Tilemap#bitmaps`: the nine sheets (A1-A5, then B, C, D, E),
// addressed by index. The scripts assign into it — `@tilemap.bitmaps[i] =
// Cache.tileset(name)` — so hand back the same Array every time and let the
// next refresh pick the change up (Spriteset_Map calls #update every frame).
mrb_value tilemap_bitmaps(mrb_state* M, mrb_value self) {
  mrb_value a = mrb_iv_get(M, self, MRB_IVSYM(bitmaps));
  if (!mrb_array_p(a)) {
    a = mrb_ary_new_capa(M, 9);
    for (int i = 0; i < 9; ++i)
      mrb_ary_push(M, a, mrb_nil_value());
    mrb_iv_set(M, self, MRB_IVSYM(bitmaps), a);
  }
  return a;
}

// RGSS2/RGSS3 `Tilemap#flags=`: RPG::Tileset#flags, one word per tile id
// (0x10 = draw above the characters, 0x80 = an A2 table tile, plus the
// passage/terrain bits the game logic reads).
mrb_value tilemap_set_flags_native_body(mrb_state* M,
                                        mrb_value self,
                                        mrb_value v) {
  mrb_iv_set(M, self, MRB_IVSYM(flags), v);
  tilemap_refresh(M, self);
  return v;
}

mrb_value tilemap_set_flags(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  return tilemap_set_flags_native_body(M, self, v);
}

// Tilemap.vx_tile_quads(tile_id, frame = 0, table = false) -> [[sheet, sx, sy,
// dx, dy, w, h], ...]
//
// The VX / VX Ace tile geometry, exposed so it can be pinned by unit tests: the
// drawing needs a display the headless test binary has not got, but the decode
// is pure arithmetic. Answers an empty Array for an id that draws nothing.
#if !defined(WIO_TERMINAL)  // dead weight on wio: no Ruby path reaches it
mrb_value tilemap_vx_tile_quads(mrb_state* M, mrb_value self) {
  mrb_int tile_id = 0, frame = 0;
  mrb_bool table = FALSE;
  mrb_get_args(M, "i|ib", &tile_id, &frame, &table);
  VXQuad quads[8];
  const int n = vx_tile_quads(static_cast<int>(tile_id),
                              static_cast<int>(frame), table != 0, quads);
  mrb_value out = mrb_ary_new_capa(M, n);
  for (int i = 0; i < n; ++i) {
    const VXQuad& q = quads[i];
    mrb_value row = mrb_ary_new_capa(M, 7);
    mrb_ary_push(M, row, mrb_fixnum_value(q.sheet));
    mrb_ary_push(M, row, mrb_fixnum_value(q.sx));
    mrb_ary_push(M, row, mrb_fixnum_value(q.sy));
    mrb_ary_push(M, row, mrb_fixnum_value(q.dx));
    mrb_ary_push(M, row, mrb_fixnum_value(q.dy));
    mrb_ary_push(M, row, mrb_fixnum_value(q.w));
    mrb_ary_push(M, row, mrb_fixnum_value(q.h));
    mrb_ary_push(M, out, row);
  }
  return out;
}
#endif  // !defined(WIO_TERMINAL)

// Tilemap.vx_table_leg_quads(tile_id) -> [[sheet, sx, sy, dx, dy, w, h], ...]
//
// The A2 table-tile "leg" that spills into the row below (see
// vx_table_leg_quads above), exposed the same way vx_tile_quads is: pure
// arithmetic, pinned without needing the display the headless test binary
// has not got.
#if !defined(WIO_TERMINAL)  // dead weight on wio: no Ruby path reaches it
mrb_value tilemap_vx_table_leg_quads_native_body(mrb_state* M,
                                                 mrb_value self,
                                                 mrb_int tile_id) {
  VXQuad legs[2];
  const int n = vx_table_leg_quads(static_cast<int>(tile_id), legs);
  mrb_value out = mrb_ary_new_capa(M, n);
  for (int i = 0; i < n; ++i) {
    const VXQuad& q = legs[i];
    mrb_value row = mrb_ary_new_capa(M, 7);
    mrb_ary_push(M, row, mrb_fixnum_value(q.sheet));
    mrb_ary_push(M, row, mrb_fixnum_value(q.sx));
    mrb_ary_push(M, row, mrb_fixnum_value(q.sy));
    mrb_ary_push(M, row, mrb_fixnum_value(q.dx));
    mrb_ary_push(M, row, mrb_fixnum_value(q.dy));
    mrb_ary_push(M, row, mrb_fixnum_value(q.w));
    mrb_ary_push(M, row, mrb_fixnum_value(q.h));
    mrb_ary_push(M, out, row);
  }
  return out;
}

mrb_value tilemap_vx_table_leg_quads(mrb_state* M, mrb_value self) {
  mrb_int tile_id = 0;
  mrb_get_args(M, "i", &tile_id);
  return tilemap_vx_table_leg_quads_native_body(M, self, tile_id);
}
#endif  // !defined(WIO_TERMINAL)

// Show/hide the tilemap, propagating to the priority "above" layer so a hidden
// tilemap hides its roofs too (the above canvas is a separate LVGL object that
// obj_set_visible on the tilemap alone would leave showing).
mrb_value tilemap_set_visible(mrb_state* M, mrb_value self) {
  mrb_bool v;
  mrb_get_args(M, "b", &v);
  return rgss::tilemap_visible_set_direct(M, self, v);
}

// Sets the tilemap's own z and keeps the priority "above" layer pinned
// TILEMAP_ABOVE_Z higher than it, the same z= propagation
// tilemap_set_visible already does for visibility. The generic obj_set_z
// only ever touched `self`'s own `@z`; the above canvas (`@_tm_above_obj`,
// a separate LVGL object of its own -- see tilemap_init) was left at its
// construction-time z forever, so a script that ever reassigned a
// tilemap's z (moving it behind/above some other z-managed object) lost
// the "above sorts over characters" relationship the two layers are
// supposed to keep in lockstep, since only the ground canvas actually
// moved.
mrb_value tilemap_set_z(mrb_state* M, mrb_value self) {
  mrb_int z;
  mrb_get_args(M, "i", &z);
  return rgss::tilemap_z_set_direct(M, self, z);
}

// Real RGSS treats `ox`/`oy` as a cheap, hardware-composited draw offset --
// stock Spriteset_Map#update reassigns it every single frame regardless of
// whether the camera actually moved. This engine instead re-composites the
// whole visible tile grid into a CPU-side canvas on every assignment, so
// without a same-value guard, a stationary camera still pays a full refresh
// every frame -- observed via a real VX Ace game's boot hanging for minutes
// on hundreds of consecutive `ox=`/`oy=` calls, each to the exact same
// value already stored, before the game's own script host ever reaches its
// first Graphics.update.
mrb_value tilemap_set_ox_native_body(mrb_state* M, mrb_value self, mrb_int v) {
  const mrb_value cur = mrb_iv_get(M, self, MRB_IVSYM(ox));
  if (mrb_fixnum_p(cur) && mrb_fixnum(cur) == v)
    return self;
  mrb_iv_set(M, self, MRB_IVSYM(ox), mrb_fixnum_value(v));
  tilemap_refresh(M, self);
  return self;
}

mrb_value tilemap_set_ox(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return tilemap_set_ox_native_body(M, self, v);
}

mrb_value tilemap_set_oy_native_body(mrb_state* M, mrb_value self, mrb_int v) {
  const mrb_value cur = mrb_iv_get(M, self, MRB_IVSYM(oy));
  if (mrb_fixnum_p(cur) && mrb_fixnum(cur) == v)
    return self;
  mrb_iv_set(M, self, MRB_IVSYM(oy), mrb_fixnum_value(v));
  tilemap_refresh(M, self);
  return self;
}

mrb_value tilemap_set_oy(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return tilemap_set_oy_native_body(M, self, v);
}

// ---- Window ---------------------------------------------------------------

mrb_value make_rect(mrb_state* M, mrb_int x, mrb_int y, mrb_int w, mrb_int h);
double vp_tone_key(const Tone& t);
static mrb_int clamp_opacity(mrb_state* M, mrb_value self, const char* iv);

// RGSS insets a window's contents 16px from its frame on every side, so the
// drawable content area is (width - 32) x (height - 32).
static const int WINDOW_PADDING = 16;

// (Re)allocate the window's canvas Bitmap to w x h when the size changes and
// point the lv_canvas at it. Held in @_win_canvas so the GC keeps it alive.
Bitmap& window_ensure_canvas(mrb_state* M,
                             mrb_value self,
                             mrb_int w,
                             mrb_int h) {
  if (w < 1)
    w = 1;
  if (h < 1)
    h = 1;
  // Unlike window_refresh/window_update's own "already gone, nothing to
  // paint" early return, a size change is driven by explicit width=/height=
  // assignments -- so a disposed window here raises the same way the other
  // explicit Sprite/Viewport/Window setters do (obj_require), rather than
  // silently doing nothing.
  gfx::Node* obj = obj_require(M, self);
  const mrb_value cur = mrb_iv_get(M, self, MRB_IVSYM(_win_canvas));
  if (!mrb_nil_p(cur)) {
    Bitmap& c = DataType<Bitmap>::get(M, cur);
    if (c.width == w && c.height == h)
      return c;
  }
  RClass* bmp_class = mrb_class_get_under_id(
      M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Bitmap));
  const mrb_value cv =
      DataType<Bitmap>::make(M, bmp_class, w, h, kPixelARGB8888);
  Bitmap& c = DataType<Bitmap>::get(M, cv);
  gfx::sprite_set_pixels(obj, c.buffer.data(), w, h, kPixelARGB8888);
  gfx::node_set_size(obj, w, h);
  mrb_iv_set(M, self, MRB_IVSYM(_win_canvas), cv);
  return c;
}

// (Re)allocate the window's *structural* composite -- background, frame and
// contents, i.e. everything window_refresh draws except the blinking cursor
// and the pause arrow -- to w x h when the size changes. Held in
// @_win_structural so the GC keeps it alive across frames: a window with an
// active cursor redraws that furniture every frame (window_update), but the
// background/frame/contents underneath it only actually change when their
// own inputs do (window_structural_dirty), so this buffer lets window_refresh
// cache that work instead of recompositing the whole skin every frame just to
// blink a cursor.
mrb_value window_ensure_structural(mrb_state* M,
                                   mrb_value self,
                                   mrb_int w,
                                   mrb_int h) {
  if (w < 1)
    w = 1;
  if (h < 1)
    h = 1;
  const mrb_value cur = mrb_iv_get(M, self, MRB_IVSYM(_win_structural));
  if (!mrb_nil_p(cur)) {
    Bitmap& c = DataType<Bitmap>::get(M, cur);
    if (c.width == w && c.height == h)
      return cur;
  }
  RClass* bmp_class = mrb_class_get_under_id(
      M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Bitmap));
  const mrb_value sv =
      DataType<Bitmap>::make(M, bmp_class, w, h, kPixelARGB8888);
  mrb_iv_set(M, self, MRB_IVSYM(_win_structural), sv);
  return sv;
}

// Whether the window's structural composite (background + frame + contents)
// needs to be rebuilt this frame: any of its inputs changed since the last
// check, or the contents bitmap was drawn into (Bitmap#draw_text, #blt, ...
// all set Bitmap.dirty). The key is a flat string of every input rather than
// several ivars so one string compare covers the lot; @_win_struct_key is
// GC-owned like @_tone_key already is for window_sync_tone.
//
// Reading contents.dirty here *consumes* it: once observed, the pending
// change is folded into the freshly rebuilt composite, so nothing else needs
// to reset the flag (nothing else reads a Window's @contents.dirty -- see
// window_refresh's header comment).
static bool window_structural_dirty(mrb_state* M,
                                    mrb_value self,
                                    mrb_int w,
                                    mrb_int h) {
  const mrb_value skin = mrb_iv_get(M, self, MRB_IVSYM(windowskin));
  const mrb_int op = clamp_opacity(M, self, "@opacity");
  const mrb_int back = clamp_opacity(M, self, "@back_opacity");
  const mrb_value st = mrb_iv_get(M, self, MRB_IVSYM(stretch));
  const bool stretch = mrb_nil_p(st) ? true : mrb_test(st);
  const mrb_value tv = mrb_iv_get(M, self, MRB_IVSYM(tone));
  const double tone_key = (mrb_test(tv) && DATA_PTR(tv))
                              ? vp_tone_key(DataType<Tone>::get(M, tv))
                              : 0.0;
  const mrb_value cont = mrb_iv_get(M, self, MRB_IVSYM(contents));
  const mrb_int cop = clamp_opacity(M, self, "@contents_opacity");
  const mrb_int ox = mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(ox)));
  const mrb_int oy = mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(oy)));
  Bitmap* cont_bmp = (mrb_test(cont) && DATA_PTR(cont))
                         ? &DataType<Bitmap>::get(M, cont)
                         : nullptr;
  const bool content_dirty = cont_bmp && cont_bmp->dirty;

  char buf[256];
  std::snprintf(buf, sizeof(buf),
                "%p|%lld|%lld|%lld|%lld|%d|%.6f|%p|%lld|%lld|%lld",
                mrb_test(skin) ? DATA_PTR(skin) : nullptr, (long long)w,
                (long long)h, (long long)op, (long long)back, stretch ? 1 : 0,
                tone_key, static_cast<void*>(cont_bmp), (long long)cop,
                (long long)ox, (long long)oy);

  const mrb_value prev = mrb_iv_get(M, self, MRB_IVSYM(_win_struct_key));
  const bool key_changed =
      !mrb_string_p(prev) || std::strcmp(RSTRING_PTR(prev), buf) != 0;
  if (key_changed) {
    mrb_iv_set(M, self, MRB_IVSYM(_win_struct_key), mrb_str_new_cstr(M, buf));
  }
  if (content_dirty)
    cont_bmp->dirty = false;
  return key_changed || content_dirty;
}

// An integer ivar, or `dflt` when it was never assigned. The RGSS2/RGSS3-only
// window attributes are plain state the scripts drive, so a window that
// predates them -- an RGSS1 one, or a VX one before its first `openness=` --
// has no such ivar at all.
static mrb_int iv_int_or(mrb_state* M,
                         mrb_value self,
                         const char* iv,
                         mrb_int dflt) {
  const mrb_value v = mrb_iv_get(M, self, mrb_intern_cstr(M, iv));
  return mrb_nil_p(v) ? dflt : mrb_as_int(M, v);
}

// RGSS2/RGSS3 Window#tone: a colour tone over the window's *background*, not
// its frame and not its contents. Applied to the whole canvas right after the
// background is laid down and before anything is drawn on top, which is what
// confines it to the background without a second buffer.
//
// Unlike Viewport#tone this is not folded in by each child: a window composites
// itself, so it tones its own pixels. The per-pixel maths is the shared
// apply_tone_px, so the three tone paths cannot drift apart.
static void window_apply_tone(mrb_state* M, mrb_value self, Bitmap& canvas) {
  const mrb_value tv = mrb_iv_get(M, self, MRB_IVSYM(tone));
  if (!mrb_test(tv) || !DATA_PTR(tv))
    return;
  const Tone& tn = DataType<Tone>::get(M, tv);
  if (!tone_is_set(tn))
    return;
  for (int y = 0; y < canvas.height; ++y) {
    for (int x = 0; x < canvas.width; ++x) {
      int r, g, b, a;
      bmp_read(canvas, x, y, r, g, b, a);
      if (a == 0)
        continue;
      apply_tone_px(r, g, b, tn);
      bmp_put(canvas, x, y, r, g, b, a);
    }
  }
  canvas.dirty = true;
}

// An opacity ivar clamped to 0..255, defaulting to RGSS's 255 when the script
// never assigned one. It used to read the ivar unconditionally, so setting a
// windowskin on a window whose opacity had not been set was a TypeError on nil
// -- window_init sets @contents_opacity but not @opacity or @back_opacity.
// Nothing hit it while RGSS::Window was unreachable (see the note on
// RPG2k::Window); it raises on the first real use once it is not.
static mrb_int clamp_opacity(mrb_state* M, mrb_value self, const char* iv) {
  const mrb_value raw = mrb_iv_get(M, self, mrb_intern_cstr(M, iv));
  if (mrb_nil_p(raw))
    return 255;
  const mrb_int v = mrb_as_int(M, raw);
  if (v < 0)
    return 0;
  if (v > 255)
    return 255;
  return v;
}

// Repaint the window canvas: draw the windowskin background + 9-slice frame
// (if a windowskin is set) and the contents bitmap (inset by WINDOW_PADDING,
// scrolled by ox/oy) into a cached *structural* composite, then copy that
// composite onto the visible canvas and draw the blinking cursor / pause
// arrow on top. The compositing reuses the tested
// Bitmap#clear/#stretch_blt/#blt methods via mrb_funcall; only the RMXP
// windowskin source rects are new here (the 128x128 background at (0,0) and
// the 64x64 frame at (128,0) with 16px corners).
//
// window_update calls this every frame a window has an active cursor or is
// paused, so the blink alone used to force a full skin+contents recomposite
// (background tile, 9-slice frame, contents blit -- up to a dozen Bitmap#blt
// calls) every single frame. window_structural_dirty gates that work behind
// whether the background/frame/contents inputs actually changed; the common
// case -- an open menu with nothing but a blinking cursor -- now redraws just
// the cursor (and the cached composite's one-shot copy onto the canvas) per
// frame instead.
void window_refresh(mrb_state* M, mrb_value self) {
  gfx::Node* obj = display_node(self);
  if (!obj)
    return;
  const mrb_int w = mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(width)));
  const mrb_int full_h = mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(height)));
  // RGSS2/RGSS3 openness: the window unrolls from its horizontal centre line,
  // so it is drawn at a fraction of its height and shifted down by half of what
  // it lost. Every VX window opens and closes this way (`Window_Base#open`
  // steps openness by 48 a frame), and RGSS hides the contents until it is
  // fully open. 255 -- the default, and every RGSS1 window -- is the ordinary
  // full draw.
  const mrb_int openness = std::min<mrb_int>(
      255, std::max<mrb_int>(0, iv_int_or(M, self, "@openness", 255)));
  const mrb_int h = full_h * openness / 255;
  gfx::node_set_y(obj,
                  (int32_t)(iv_int_or(M, self, "@y", 0) + (full_h - h) / 2));
  if (h <= 0) {
    // Fully closed: nothing to draw, and a zero-height canvas is not a valid
    // LVGL buffer, so size the object away instead.
    gfx::node_set_size(obj, (int32_t)w, 0);
    gfx::node_invalidate(obj);
    return;
  }
  window_ensure_canvas(M, self, w, h);
  const mrb_value canvas = mrb_iv_get(M, self, MRB_IVSYM(_win_canvas));
  const mrb_sym blt = MRB_SYM(blt);
  const mrb_sym sblt = MRB_SYM(stretch_blt);
  // The compositing allocates transient Rect values; drop them off the GC arena
  // when done (canvas/skin/contents stay alive via their ivars on self).
  const int arena = mrb_gc_arena_save(M);

  const bool structural_dirty = window_structural_dirty(M, self, w, h);
  const mrb_value structural = window_ensure_structural(M, self, w, h);
  const mrb_value skin = mrb_iv_get(M, self, MRB_IVSYM(windowskin));
  const mrb_int b = WINDOW_PADDING;

  if (structural_dirty) {
    mrb_funcall_argv(M, structural, MRB_SYM(clear), 0, nullptr);

    if (mrb_test(skin) && DATA_PTR(skin)) {
      const mrb_int op = clamp_opacity(M, self, "@opacity");
      const mrb_int back = op * clamp_opacity(M, self, "@back_opacity") / 255;
      // Background from the 128x128 tile at (0,0). RMXP's `stretch` (default
      // true) scales that tile over the whole window; when false it is tiled
      // at 1:1, repeating across the window (edge tiles clip against the
      // canvas).
      const mrb_value st = mrb_iv_get(M, self, MRB_IVSYM(stretch));
      const bool stretch = mrb_nil_p(st) ? true : mrb_test(st);
      if (stretch) {
        const mrb_value bg[] = {make_rect(M, 0, 0, w, h), skin,
                                make_rect(M, 0, 0, 128, 128),
                                mrb_fixnum_value(back)};
        mrb_funcall_argv(M, structural, sblt, 4, bg);
      } else {
        for (mrb_int ty = 0; ty < h; ty += 128) {
          for (mrb_int tx = 0; tx < w; tx += 128) {
            const mrb_value bg[] = {mrb_fixnum_value(tx), mrb_fixnum_value(ty),
                                    skin, make_rect(M, 0, 0, 128, 128),
                                    mrb_fixnum_value(back)};
            mrb_funcall_argv(M, structural, blt, 5, bg);
          }
        }
      }
      // The tone tints the background only, so it goes on before the frame
      // and the contents are drawn over it.
      window_apply_tone(M, self, DataType<Bitmap>::get(M, structural));
      // Frame: the 64x64 border at (128,0), a 9-slice with 16px
      // corners/margins. The corner shrinks vertically with a part-open
      // window, so a half-unrolled one keeps a frame instead of drawing its
      // top and bottom borders over each other (h is the *drawn* height --
      // see openness above).
      const mrb_int bv = std::min<mrb_int>(b, h / 2);
      if (bv > 0) {
        const mrb_value tl[] = {mrb_fixnum_value(0), mrb_fixnum_value(0), skin,
                                make_rect(M, 128, 0, b, bv),
                                mrb_fixnum_value(op)};
        mrb_funcall_argv(M, structural, blt, 5, tl);
        const mrb_value tr[] = {mrb_fixnum_value(w - b), mrb_fixnum_value(0),
                                skin, make_rect(M, 176, 0, b, bv),
                                mrb_fixnum_value(op)};
        mrb_funcall_argv(M, structural, blt, 5, tr);
        const mrb_value bl[] = {mrb_fixnum_value(0), mrb_fixnum_value(h - bv),
                                skin, make_rect(M, 128, 64 - bv, b, bv),
                                mrb_fixnum_value(op)};
        mrb_funcall_argv(M, structural, blt, 5, bl);
        const mrb_value br[] = {
            mrb_fixnum_value(w - b), mrb_fixnum_value(h - bv), skin,
            make_rect(M, 176, 64 - bv, b, bv), mrb_fixnum_value(op)};
        mrb_funcall_argv(M, structural, blt, 5, br);
        const mrb_value top[] = {make_rect(M, b, 0, w - 2 * b, bv), skin,
                                 make_rect(M, 144, 0, 32, bv),
                                 mrb_fixnum_value(op)};
        mrb_funcall_argv(M, structural, sblt, 4, top);
        const mrb_value bottom[] = {make_rect(M, b, h - bv, w - 2 * b, bv),
                                    skin, make_rect(M, 144, 64 - bv, 32, bv),
                                    mrb_fixnum_value(op)};
        mrb_funcall_argv(M, structural, sblt, 4, bottom);
      }
      if (h > 2 * bv) {
        const mrb_value left[] = {make_rect(M, 0, bv, b, h - 2 * bv), skin,
                                  make_rect(M, 128, 16, b, 32),
                                  mrb_fixnum_value(op)};
        mrb_funcall_argv(M, structural, sblt, 4, left);
        const mrb_value right[] = {make_rect(M, w - b, bv, b, h - 2 * bv), skin,
                                   make_rect(M, 176, 16, b, 32),
                                   mrb_fixnum_value(op)};
        mrb_funcall_argv(M, structural, sblt, 4, right);
      }
    } else {
      // No windowskin: the tone still applies to whatever background there
      // is.
      window_apply_tone(M, self, DataType<Bitmap>::get(M, structural));
    }

    // Contents is furniture RGSS hides while a window is opening or closing
    // (only the frame animates), same as the cursor and pause arrow below.
    if (openness == 255) {
      const mrb_value cont = mrb_iv_get(M, self, MRB_IVSYM(contents));
      if (mrb_test(cont) && DATA_PTR(cont)) {
        const mrb_int cop = clamp_opacity(M, self, "@contents_opacity");
        const mrb_int ox = mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(ox)));
        const mrb_int oy = mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(oy)));
        // Blit the scrolled contents into the content area, inset by
        // WINDOW_PADDING.
        const mrb_value c[] = {mrb_fixnum_value(b), mrb_fixnum_value(b), cont,
                               make_rect(M, ox, oy, w - 2 * b, h - 2 * b),
                               mrb_fixnum_value(cop)};
        mrb_funcall_argv(M, structural, blt, 5, c);
      }
    }
  }

  // Copy the (possibly cached) structural composite onto the visible canvas
  // -- one full-size blit standing in for the whole background+frame+contents
  // recomposite above whenever it was skipped this frame.
  mrb_funcall_argv(M, canvas, MRB_SYM(clear), 0, nullptr);
  const mrb_value full[] = {mrb_fixnum_value(0), mrb_fixnum_value(0),
                            structural, make_rect(M, 0, 0, w, h),
                            mrb_fixnum_value(255)};
  mrb_funcall_argv(M, canvas, blt, 5, full);

  // Everything below is window *furniture* -- cursor, pause arrow -- which
  // RGSS hides entirely while a window is opening or closing.
  if (openness < 255) {
    mrb_gc_arena_restore(M, arena);
    gfx::node_invalidate(obj);
    return;
  }

  const mrb_int anim = mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(_anim)));
  // Cursor: a blinking highlight from the windowskin cursor region (128,64,
  // 32,32) drawn at cursor_rect (content coords, offset by the padding), when
  // the window is active. It is a 9-slice with 2px corners (matching
  // RMXP/mkxp's buildFrame): the four 2x2 corners are copied 1:1, the four
  // edges are stretched along one axis and the centre fills the rest. The blink
  // alpha oscillates with @_anim. Redrawn each frame by Window#update because
  // scripts mutate cursor_rect in place.
  const mrb_value cr_v = mrb_iv_get(M, self, MRB_IVSYM(cursor_rect));
  const mrb_value active_v = mrb_iv_get(M, self, MRB_IVSYM(active));
  const bool active = mrb_nil_p(active_v) ? true : mrb_test(active_v);
  if (mrb_test(skin) && DATA_PTR(skin) && active && mrb_test(cr_v) &&
      DATA_PTR(cr_v)) {
    Rect& cr = DataType<Rect>::get(M, cr_v);
    if (cr.width > 0 && cr.height > 0) {
      const mrb_int phase = ((anim % 32) + 32) % 32;
      const mrb_int level = phase < 16 ? phase : 32 - phase;  // 0..16
      const mrb_int calpha = 255 - level * 8;                 // 255..127
      const mrb_value op = mrb_fixnum_value(calpha);
      const mrb_int dx = b + cr.x, dy = b + cr.y, dw = cr.width, dh = cr.height;
      // The cursor skin region and its 2px 9-slice corner size.
      const int sx = 128, sy = 64, ss = 32, k = 2;
      if (dw >= 2 * k && dh >= 2 * k) {
        // Corners (blt, 1:1). {tl, tr, bl, br} as {dstx, dsty, srcx, srcy}.
        const mrb_int corners[4][4] = {
            {dx, dy, sx, sy},
            {dx + dw - k, dy, sx + ss - k, sy},
            {dx, dy + dh - k, sx, sy + ss - k},
            {dx + dw - k, dy + dh - k, sx + ss - k, sy + ss - k}};
        for (const auto& c : corners) {
          const mrb_value a[] = {mrb_fixnum_value(c[0]), mrb_fixnum_value(c[1]),
                                 skin, make_rect(M, c[2], c[3], k, k), op};
          mrb_funcall_argv(M, canvas, blt, 5, a);
        }
        // Edges (stretch_blt) as {dstRect..., srcRect...}: top, bottom, left,
        // right. Top/bottom stretch horizontally, left/right vertically.
        const mrb_int edges[4][8] = {
            {dx + k, dy, dw - 2 * k, k, sx + k, sy, ss - 2 * k, k},
            {dx + k, dy + dh - k, dw - 2 * k, k, sx + k, sy + ss - k,
             ss - 2 * k, k},
            {dx, dy + k, k, dh - 2 * k, sx, sy + k, k, ss - 2 * k},
            {dx + dw - k, dy + k, k, dh - 2 * k, sx + ss - k, sy + k, k,
             ss - 2 * k}};
        for (const auto& e : edges) {
          const mrb_value a[] = {make_rect(M, e[0], e[1], e[2], e[3]), skin,
                                 make_rect(M, e[4], e[5], e[6], e[7]), op};
          mrb_funcall_argv(M, canvas, sblt, 4, a);
        }
        // Centre (stretch_blt).
        const mrb_value ctr[] = {
            make_rect(M, dx + k, dy + k, dw - 2 * k, dh - 2 * k), skin,
            make_rect(M, sx + k, sy + k, ss - 2 * k, ss - 2 * k), op};
        mrb_funcall_argv(M, canvas, sblt, 4, ctr);
      } else {
        // Rect too small for the 9-slice: fall back to a plain stretch.
        const mrb_value cur[] = {make_rect(M, dx, dy, dw, dh), skin,
                                 make_rect(M, sx, sy, ss, ss), op};
        mrb_funcall_argv(M, canvas, sblt, 4, cur);
      }
    }
  }
  // Pause arrow: one of four 16x16 frames at (160,64) cycled by @_anim, drawn
  // centred on the bottom edge when the window is paused.
  if (mrb_test(skin) && DATA_PTR(skin) &&
      mrb_test(mrb_iv_get(M, self, MRB_IVSYM(pause)))) {
    const mrb_int f = (anim / 8) % 4;
    const mrb_value pa[] = {
        mrb_fixnum_value(w / 2 - 8), mrb_fixnum_value(h - 16), skin,
        make_rect(M, 160 + (f % 2) * 16, 64 + (f / 2) * 16, 16, 16),
        mrb_fixnum_value(255)};
    mrb_funcall_argv(M, canvas, blt, 5, pa);
  }
  mrb_gc_arena_restore(M, arena);
  gfx::node_invalidate(obj);
}

mrb_value window_init(mrb_state* M, mrb_value self) {
  mrb_value vp = mrb_nil_value();
  mrb_get_args(M, "|o", &vp);
  display_init(M, self, &window_type);
  gfx::Node* c = gfx::sprite_new(parent_object(M, vp));
  wrap_node(M, self, c);
  register_zobj(M, self);
  gfx::node_set_pos(c, 0, 0);
  mrb_iv_set(M, self, MRB_IVSYM(viewport), vp);
  // RGSS3's own stock Window_Base#create_contents (every VX Ace project ships
  // it unmodified) calls `contents.dispose` unconditionally as its first line
  // -- real RGSS never leaves a freshly constructed Window's `contents` nil,
  // it starts as a real (if trivial) Bitmap so that always-safe first dispose
  // has something to act on.
  RClass* initial_contents_bmp_class = mrb_class_get_under_id(
      M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Bitmap));
  const mrb_value initial_contents = DataType<Bitmap>::make(
      M, initial_contents_bmp_class, 1, 1, kPixelARGB8888);
  mrb_iv_set(M, self, MRB_IVSYM(contents), initial_contents);
  mrb_iv_set(M, self, MRB_IVSYM(width), mrb_fixnum_value(0));
  mrb_iv_set(M, self, MRB_IVSYM(height), mrb_fixnum_value(0));
  mrb_iv_set(M, self, MRB_IVSYM(ox), mrb_fixnum_value(0));
  mrb_iv_set(M, self, MRB_IVSYM(oy), mrb_fixnum_value(0));
  mrb_iv_set(M, self, MRB_IVSYM(contents_opacity), mrb_fixnum_value(255));
  mrb_iv_set(M, self, MRB_IVSYM(_anim), mrb_fixnum_value(0));
  window_ensure_canvas(M, self, 1, 1);
  return self;
}

mrb_value window_set_contents(mrb_state* M, mrb_value self) {
  mrb_value bmp;
  mrb_get_args(M, "o", &bmp);
  return rgss::window_contents_set_direct(M, self, bmp);
}

mrb_value window_set_width(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return rgss::window_width_set_direct(M, self, v);
}

mrb_value window_set_height(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return rgss::window_height_set_direct(M, self, v);
}

mrb_value window_set_ox_native_body(mrb_state* M, mrb_value self, mrb_int v) {
  mrb_iv_set(M, self, MRB_IVSYM(ox), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_ox(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return window_set_ox_native_body(M, self, v);
}

mrb_value window_set_oy_native_body(mrb_state* M, mrb_value self, mrb_int v) {
  mrb_iv_set(M, self, MRB_IVSYM(oy), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_oy(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return window_set_oy_native_body(M, self, v);
}

mrb_value window_set_contents_opacity_native_body(mrb_state* M,
                                                  mrb_value self,
                                                  mrb_int v) {
  mrb_iv_set(M, self, MRB_IVSYM(contents_opacity), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_contents_opacity(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return window_set_contents_opacity_native_body(M, self, v);
}

mrb_value window_set_skin(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  return rgss::window_windowskin_set_direct(M, self, v);
}

mrb_value window_set_opacity_native_body(mrb_state* M,
                                         mrb_value self,
                                         mrb_int v) {
  mrb_iv_set(M, self, MRB_IVSYM(opacity), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_opacity(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return window_set_opacity_native_body(M, self, v);
}

mrb_value window_set_back_opacity_native_body(mrb_state* M,
                                              mrb_value self,
                                              mrb_int v) {
  mrb_iv_set(M, self, MRB_IVSYM(back_opacity), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_back_opacity(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return window_set_back_opacity_native_body(M, self, v);
}

mrb_value window_set_cursor_rect(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  return rgss::window_cursor_rect_set_direct(M, self, v);
}

mrb_value window_set_active(mrb_state* M, mrb_value self) {
  mrb_bool v;
  mrb_get_args(M, "b", &v);
  return rgss::window_active_set_direct(M, self, v);
}

mrb_value window_set_pause(mrb_state* M, mrb_value self) {
  mrb_bool v;
  mrb_get_args(M, "b", &v);
  return rgss::window_pause_set_direct(M, self, v);
}

mrb_value window_set_stretch_native_body(mrb_state* M,
                                         mrb_value self,
                                         mrb_bool v) {
  mrb_iv_set(M, self, MRB_IVSYM(stretch), mrb_bool_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_stretch(mrb_state* M, mrb_value self) {
  mrb_bool v;
  mrb_get_args(M, "b", &v);
  return window_set_stretch_native_body(M, self, v);
}

// RGSS3 (VX Ace) added `Window#viewport=`: a window can be (re)assigned to a
// Viewport after construction, the same way Scene_Battle's stock windows are,
// so they clip and scroll with the battle viewport instead of the screen.
// `window_init` already threads an optional viewport through to
// `parent_object` at construction time, matching Sprite's own constructor --
// but nothing reassigns it afterward, which is what real games actually call
// (VX Ace's `Window.new(x, y, width, height)` never passes one). Reparenting
// via LVGL is the whole mechanism: the window's canvas becomes a child of the
// new viewport's (clipped, scrollable) content layer -- or the root screen
// for `nil`, via the same `parent_object` construction uses -- and
// `gfx_update`'s z-sort already groups by each object's live LVGL parent
// every frame, so no further z-order or compositing change is needed.
mrb_value window_set_viewport_native_body(mrb_state* M,
                                          mrb_value self,
                                          mrb_value vp) {
  gfx::Node* obj = obj_require(M, self);
  gfx::node_reparent(obj, parent_object(M, vp));
  mrb_iv_set(M, self, MRB_IVSYM(viewport), vp);
  update_z(M);
  return vp;
}

mrb_value window_set_viewport(mrb_state* M, mrb_value self) {
  mrb_value vp;
  mrb_get_args(M, "o", &vp);
  return window_set_viewport_native_body(M, self, vp);
}

// A single number standing for a Tone's four channels, so a change can be
// spotted with one comparison. Shared with the viewport's tone tracking.
double vp_tone_key(const Tone& t);

// RGSS2/RGSS3 Window#openness: 0 (closed) .. 255 (open). Native rather than
// plain state because assigning it has to redraw -- the frame is drawn at a
// fraction of its height (see window_refresh), which *is* the open/close
// animation. `Window_Base#open` steps this by 48 a frame.
mrb_value window_set_openness_body(mrb_state* M, mrb_value self, mrb_int v);

mrb_value window_set_openness_native_body(mrb_state* M,
                                          mrb_value self,
                                          mrb_int v) {
  return window_set_openness_body(M, self, v);
}

mrb_value window_set_openness(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return window_set_openness_native_body(M, self, v);
}

mrb_value window_set_openness_body(mrb_state* M, mrb_value self, mrb_int v) {
  v = std::min<mrb_int>(255, std::max<mrb_int>(0, v));
  mrb_iv_set(M, self, MRB_IVSYM(openness), mrb_fixnum_value(v));
  window_refresh(M, self);
  return mrb_fixnum_value(v);
}

// RGSS2/RGSS3 Window#tone, created on first read like the viewport's so
// `window.tone.set(...)` has something to mutate.
mrb_value window_tone(mrb_state* M, mrb_value self) {
  mrb_value t = mrb_iv_get(M, self, MRB_IVSYM(tone));
  if (mrb_nil_p(t)) {
    const mrb_value args[] = {mrb_fixnum_value(0), mrb_fixnum_value(0),
                              mrb_fixnum_value(0), mrb_fixnum_value(0)};
    t = mrb_obj_new(M,
                    mrb_class_get_under_id(
                        M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Tone)),
                    4, args);
    mrb_iv_set(M, self, MRB_IVSYM(tone), t);
  }
  return t;
}

mrb_value window_set_tone_body(mrb_state* M, mrb_value self, mrb_value t);

mrb_value window_set_tone_native_body(mrb_state* M,
                                      mrb_value self,
                                      mrb_value t) {
  return window_set_tone_body(M, self, t);
}

mrb_value window_set_tone(mrb_state* M, mrb_value self) {
  mrb_value t;
  mrb_get_args(M, "o", &t);
  return window_set_tone_native_body(M, self, t);
}

mrb_value window_set_tone_body(mrb_state* M, mrb_value self, mrb_value t) {
  mrb_iv_set(M, self, MRB_IVSYM(tone), t);
  window_refresh(M, self);
  return t;
}

// Whether the tone changed since the last check. The scripts mutate the Tone
// *in place* (`window.tone.set(...)`) and call update every frame, so
// assignment alone is not enough to notice -- the same reason Viewport#tone is
// re-checked from its own update. One comparison when it did not move.
bool window_sync_tone(mrb_state* M, mrb_value self) {
  const mrb_value tv = mrb_iv_get(M, self, MRB_IVSYM(tone));
  const double key = (mrb_test(tv) && DATA_PTR(tv))
                         ? vp_tone_key(DataType<Tone>::get(M, tv))
                         : 0.0;
  const mrb_value prev = mrb_iv_get(M, self, MRB_IVSYM(_tone_key));
  if (rgss::key_is(M, prev, key))
    return false;
  mrb_iv_set(M, self, MRB_IVSYM(_tone_key), rgss::key_value(M, key));
  return true;
}

// Per-frame tick: advance the blink/pause animation and, when the window has a
// visible cursor or is paused, redraw so the animation and any in-place
// cursor_rect mutation show. Windows without a cursor or pause need no
// per-frame work beyond the tone check, which is one comparison.
mrb_value window_update(mrb_state* M, mrb_value self) {
  const mrb_int anim = mrb_as_int(M, mrb_iv_get(M, self, MRB_IVSYM(_anim)));
  mrb_iv_set(M, self, MRB_IVSYM(_anim), mrb_fixnum_value(anim + 1));
  const mrb_value cr = mrb_iv_get(M, self, MRB_IVSYM(cursor_rect));
  const mrb_value active_v = mrb_iv_get(M, self, MRB_IVSYM(active));
  const bool active = mrb_nil_p(active_v) ? true : mrb_test(active_v);
  const bool has_cursor = active && mrb_test(cr) && DATA_PTR(cr) &&
                          DataType<Rect>::get(M, cr).width > 0;
  const bool paused = mrb_test(mrb_iv_get(M, self, MRB_IVSYM(pause)));
  const bool tone_moved = window_sync_tone(M, self);
  if (has_cursor || paused || tone_moved)
    window_refresh(M, self);
  return self;
}

#endif  // !defined(WIO_TERMINAL)

// ---- Viewport -------------------------------------------------------------

// Build an RGSS::Rect value.
mrb_value make_rect(mrb_state* M, mrb_int x, mrb_int y, mrb_int w, mrb_int h) {
  const mrb_value args[] = {mrb_fixnum_value(x), mrb_fixnum_value(y),
                            mrb_fixnum_value(w), mrb_fixnum_value(h)};
  return mrb_obj_new(M,
                     mrb_class_get_under_id(
                         M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Rect)),
                     4, args);
}

// Repaint the viewport's colour/flash overlay (defined with the rest of the
// overlay below; declared here because a rect change has to resize it).
void vp_refresh_overlay(mrb_state* M, mrb_value self);

// Push the stored @rect / @ox / @oy onto the underlying LVGL objects: the outer
// frame takes the rect's position and size (and clips to it), while the inner
// content layer is shifted by (-ox, -oy) to scroll its sprites.
void vp_apply(mrb_state* M, mrb_value self) {
  gfx::Node* outer = display_node(self);
  if (!outer)
    return;
  Rect& r = DataType<Rect>::get(M, mrb_iv_get(M, self, MRB_IVSYM(rect)));
  const mrb_int w = std::max<mrb_int>(r.width, 0);
  const mrb_int h = std::max<mrb_int>(r.height, 0);
  gfx::node_set_pos(outer, r.x, r.y);
  gfx::node_set_size(outer, w, h);

  gfx::Node* inner = gfx::viewport_content(outer);
  const mrb_value ox = mrb_iv_get(M, self, MRB_IVSYM(ox));
  const mrb_value oy = mrb_iv_get(M, self, MRB_IVSYM(oy));
  gfx::node_set_pos(inner, -(mrb_fixnum_p(ox) ? mrb_fixnum(ox) : 0),
                    -(mrb_fixnum_p(oy) ? mrb_fixnum(oy) : 0));
  gfx::node_set_size(inner, w, h);

  // The colour overlay covers the frame, so a resized viewport resizes it.
  vp_refresh_overlay(M, self);
}

mrb_value vp_init(mrb_state* M, mrb_value self) {
  // Viewport.new(x, y, width, height) | Viewport.new(rect) | Viewport.new
  // (the last covering the whole screen, matching RGSS).
  mrb_int x = 0, y = 0, w = 0, h = 0;
  const mrb_int argc = mrb_get_argc(M);
  if (argc == 1) {
    mrb_value rv;
    mrb_get_args(M, "o", &rv);
    Rect& r = DataType<Rect>::get(M, rv);
    x = r.x;
    y = r.y;
    w = r.width;
    h = r.height;
  } else if (argc >= 4) {
    mrb_get_args(M, "iiii", &x, &y, &w, &h);
  } else {
    int32_t dw, dh;
    gfx::display_size(get_display(M), dw, dh);
    w = dw;
    h = dh;
  }

  display_init(M, self, &viewport_type);
  gfx::Node* outer = gfx::viewport_new(game_root(get_display(M)));
  wrap_node(M, self, outer);
  register_zobj(M, self);
  mrb_iv_set(M, self, MRB_IVSYM(rect), make_rect(M, x, y, w, h));
  mrb_iv_set(M, self, MRB_IVSYM(ox), mrb_fixnum_value(0));
  mrb_iv_set(M, self, MRB_IVSYM(oy), mrb_fixnum_value(0));
  mrb_iv_set(M, self, MRB_IVSYM(visible), mrb_true_value());
  vp_apply(M, self);
  return self;
}

mrb_value vp_rect(mrb_state* M, mrb_value self) {
  return mrb_iv_get(M, self, MRB_IVSYM(rect));
}

mrb_value vp_set_rect_native_body(mrb_state* M, mrb_value self, mrb_value rv) {
  Rect& r = DataType<Rect>::get(M, rv);
  mrb_iv_set(M, self, MRB_IVSYM(rect),
             make_rect(M, r.x, r.y, r.width, r.height));
  vp_apply(M, self);
  return rv;
}

mrb_value vp_set_rect(mrb_state* M, mrb_value self) {
  mrb_value rv;
  mrb_get_args(M, "o", &rv);
  return vp_set_rect_native_body(M, self, rv);
}

mrb_value vp_ox(mrb_state* M, mrb_value self) {
  return mrb_iv_get(M, self, MRB_IVSYM(ox));
}

mrb_value vp_oy(mrb_state* M, mrb_value self) {
  return mrb_iv_get(M, self, MRB_IVSYM(oy));
}

mrb_value vp_set_ox_native_body(mrb_state* M, mrb_value self, mrb_int v) {
  mrb_iv_set(M, self, MRB_IVSYM(ox), mrb_fixnum_value(v));
  vp_apply(M, self);
  return mrb_fixnum_value(v);
}

mrb_value vp_set_ox(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return vp_set_ox_native_body(M, self, v);
}

mrb_value vp_set_oy_native_body(mrb_state* M, mrb_value self, mrb_int v) {
  mrb_iv_set(M, self, MRB_IVSYM(oy), mrb_fixnum_value(v));
  vp_apply(M, self);
  return mrb_fixnum_value(v);
}

mrb_value vp_set_oy(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return vp_set_oy_native_body(M, self, v);
}

// ---- Viewport colour overlay ----------------------------------------------
//
// RGSS's `Viewport#color` is a flat colour laid over everything the viewport
// draws, and `#flash` is the same thing on a countdown. VX / VX Ace do every
// screen effect this way — `Spriteset_Map` fades with
// `@viewport3.color.set(0, 0, 0, 255 - brightness)` and flashes with
// `@viewport2.color.set(...)` — and the RPG2000 runtime wants the same
// mechanism for its screen fade/flash.
//
// LVGL cannot tint a container, but it can draw one more child on top of one:
// the overlay is a canvas the size of the viewport, filled with the effective
// colour, held as the outer frame's last child so it composites above the
// content layer. The z sweep in gfx_update only reorders *registered* objects,
// which all live inside that content layer, so the overlay stays on top without
// taking part in z ordering. This is the same "screen-sized colour at an
// opacity" measured working for the RPG2000 fade, moved into the
// viewport so it clips, scrolls and hides with it.
//
// Note the overlay is refreshed from `#update`, not only on assignment: the
// stock scripts mutate the colour *in place* (`viewport.color.set(...)`) and
// call `viewport.update` every frame, so re-reading it per frame is what makes
// an in-place change visible. The fill is skipped unless the effective colour
// actually changed, so a static viewport costs one comparison a frame.

// The overlay, created on demand and found again through the frame, so no
// pointer to it is kept alive across a GC.
gfx::Node* vp_overlay(mrb_state* M, mrb_value self, bool create) {
  gfx::Node* outer = display_node(self);
  if (!outer)
    return nullptr;
  return gfx::viewport_overlay(outer, create);
}

// The colour the overlay should show: the viewport's `color`, with the flash
// colour composited over it (src-over) while a flash is running. RGSS fades a
// flash out linearly over its duration.
Color vp_effective_color(mrb_state* M, mrb_value self) {
  Color out{0, 0, 0, 0};
  const mrb_value color_v = mrb_iv_get(M, self, MRB_IVSYM(color));
  if (mrb_test(color_v) && DATA_PTR(color_v))
    out = DataType<Color>::get(M, color_v);

  const mrb_value count_v = mrb_iv_get(M, self, MRB_IVSYM(flash_count));
  const mrb_value flash_v = mrb_iv_get(M, self, MRB_IVSYM(flash_color));
  const mrb_int count = mrb_fixnum_p(count_v) ? mrb_fixnum(count_v) : 0;
  if (count > 0 && mrb_test(flash_v) && DATA_PTR(flash_v)) {
    const mrb_value dur_v = mrb_iv_get(M, self, MRB_IVSYM(flash_duration));
    const mrb_int duration = mrb_fixnum_p(dur_v) ? mrb_fixnum(dur_v) : count;
    const Color f = DataType<Color>::get(M, flash_v);
    const double fade = duration > 0 ? (double)count / (double)duration : 1.0;
    const double a = (f.alpha / 255.0) * fade;
    out.red = f.red * a + out.red * (1.0 - a);
    out.green = f.green * a + out.green * (1.0 - a);
    out.blue = f.blue * a + out.blue * (1.0 - a);
    out.alpha = 255.0 * a + out.alpha * (1.0 - a);
  }
  return out;
}

// Repaint the overlay from the current colour/flash state. Allocates (or
// resizes) its buffer to the viewport rect, and hides it entirely when the
// effective colour is transparent so a viewport with no effect draws nothing
// extra.
void vp_refresh_overlay(mrb_state* M, mrb_value self) {
  gfx::Node* outer = display_node(self);
  if (!outer)
    return;
  const Color c = vp_effective_color(M, self);
  const bool visible = c.alpha > 0.0;
  // The bytes bmp_put would fill the overlay bitmap with.
  if (gfx::viewport_set_color(outer, static_cast<uint8_t>(c.blue),
                              static_cast<uint8_t>(c.green),
                              static_cast<uint8_t>(c.red),
                              visible ? static_cast<uint8_t>(c.alpha) : 0))
    return;
  gfx::Node* ov = vp_overlay(M, self, visible);
  if (!ov)
    return;
  if (!visible) {
    gfx::node_set_hidden(ov, true);
    mrb_iv_set(M, self, MRB_IVSYM(_overlay_key), mrb_nil_value());
    return;
  }

  Rect& r = DataType<Rect>::get(M, mrb_iv_get(M, self, MRB_IVSYM(rect)));
  const mrb_int w = std::max<mrb_int>(r.width, 1);
  const mrb_int h = std::max<mrb_int>(r.height, 1);

  // Skip the fill when neither the colour nor the size changed since the last
  // one: #update runs this every frame. The channels are 0..255, so packing
  // them with the size into two doubles stays exact and allocates nothing.
  const double color_key =
      ((std::floor(c.red) * 256.0 + std::floor(c.green)) * 256.0 +
       std::floor(c.blue)) *
          256.0 +
      std::floor(c.alpha);
  const double size_key = (double)w * 65536.0 + (double)h;
  const mrb_value prev_color = mrb_iv_get(M, self, MRB_IVSYM(_overlay_key));
  const mrb_value prev_size = mrb_iv_get(M, self, MRB_IVSYM(_overlay_size));
  if (rgss::key_is(M, prev_color, color_key) &&
      rgss::key_is(M, prev_size, size_key)) {
    gfx::node_set_hidden(ov, false);
    return;
  }

  const mrb_value cur = mrb_iv_get(M, self, MRB_IVSYM(_overlay_bmp));
  mrb_value bmp_v = cur;
  if (mrb_nil_p(cur) || DataType<Bitmap>::get(M, cur).width != w ||
      DataType<Bitmap>::get(M, cur).height != h) {
    RClass* bmp_class = mrb_class_get_under_id(
        M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Bitmap));
    bmp_v = DataType<Bitmap>::make(M, bmp_class, w, h, kPixelARGB8888);
    mrb_iv_set(M, self, MRB_IVSYM(_overlay_bmp), bmp_v);
    Bitmap& nb = DataType<Bitmap>::get(M, bmp_v);
    gfx::sprite_set_pixels(ov, nb.buffer.data(), w, h, kPixelARGB8888);
    gfx::node_set_size(ov, w, h);
  }

  Bitmap& b = DataType<Bitmap>::get(M, bmp_v);
  for (mrb_int y = 0; y < h; ++y)
    for (mrb_int x = 0; x < w; ++x)
      bmp_put(b, x, y, c.red, c.green, c.blue, c.alpha);
  b.dirty = true;
  gfx::node_set_hidden(ov, false);
  gfx::node_raise(ov);
  gfx::node_invalidate(ov);
  mrb_iv_set(M, self, MRB_IVSYM(_overlay_key), rgss::key_value(M, color_key));
  mrb_iv_set(M, self, MRB_IVSYM(_overlay_size), rgss::key_value(M, size_key));
}

// Re-composite every display object that lives in this viewport, so a tone
// change reaches what is already on screen. Each object bakes the viewport's
// tone into its own buffer when it composites (see viewport_tone), and only
// re-composites when something it owns changes -- so the viewport has to poke
// them. The z-order registry is the list of live display objects, and each one
// records the viewport it was created in.
void vp_refresh_children(mrb_state* M, mrb_value self) {
  RClass* rgss = mrb_module_get_id(M, MRB_SYM(RGSS));
  RClass* spr_class = mrb_class_get_under_id(M, rgss, MRB_SYM(Sprite));
#if !defined(WIO_TERMINAL)  // Plane is never registered on wio
  RClass* plane_class = mrb_class_get_under_id(M, rgss, MRB_SYM(Plane));
  RClass* tilemap_class = mrb_class_get_under_id(M, rgss, MRB_SYM(Tilemap));
#endif  // !defined(WIO_TERMINAL)
  const mrb_value objs = zorder_objs(M);
  for (mrb_int i = 0; i < ary_size(objs); ++i) {
    const mrb_value v = ary_items(objs)[i];
    if (!display_node(v))
      continue;
    const mrb_value vp = mrb_iv_get(M, v, MRB_IVSYM(viewport));
    if (!mrb_obj_equal(M, vp, self))
      continue;
    if (mrb_obj_is_kind_of(M, v, spr_class))
      spr_bind_display(M, v, display_node(v));
#if !defined(WIO_TERMINAL)  // Plane and Tilemap: not built on wio
    else if (mrb_obj_is_kind_of(M, v, plane_class))
      plane_retile(M, v);
    else if (mrb_obj_is_kind_of(M, v, tilemap_class))
      tilemap_refresh(M, v);
#endif  // !defined(WIO_TERMINAL)
  }
}

// The tone key the child refresh is gated on: the scripts mutate the Tone in
// place (`viewport.tone.set(...)`) and call #update every frame, so the value
// is re-read per frame and the (expensive) re-composite only runs when it
// actually moved. Channels are -255..255 and gray 0..255, so this packs
// exactly.
double vp_tone_key(const Tone& t) {
  return ((std::floor(t.red) + 255.0) * 512.0 + (std::floor(t.green) + 255.0)) *
             512.0 * 512.0 +
         (std::floor(t.blue) + 255.0) * 512.0 + std::floor(t.gray);
}

// Re-composite this viewport's contents when its tone changed since the last
// check. Returns whether anything was refreshed.
bool vp_sync_tone(mrb_state* M, mrb_value self) {
  const Tone tn = viewport_tone(M, self);
  const double key = vp_tone_key(tn);
  const mrb_value prev = mrb_iv_get(M, self, MRB_IVSYM(_tone_key));
  if (rgss::key_is(M, prev, key))
    return false;
  mrb_iv_set(M, self, MRB_IVSYM(_tone_key), rgss::key_value(M, key));
  vp_refresh_children(M, self);
  return true;
}

// RGSS Viewport#tone: unlike #color (a layer over the viewport's contents), a
// tone *rescales what is drawn* -- desaturate toward luminance, then offset
// each channel -- so it cannot be an overlay. Each display object in the
// viewport folds it into its own composite instead (see viewport_tone), and
// this side makes sure they redo that when it changes.
mrb_value vp_tone(mrb_state* M, mrb_value self) {
  mrb_value t = mrb_iv_get(M, self, MRB_IVSYM(tone));
  if (mrb_nil_p(t)) {
    const mrb_value args[] = {mrb_fixnum_value(0), mrb_fixnum_value(0),
                              mrb_fixnum_value(0), mrb_fixnum_value(0)};
    t = mrb_obj_new(M,
                    mrb_class_get_under_id(
                        M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Tone)),
                    4, args);
    mrb_iv_set(M, self, MRB_IVSYM(tone), t);
  }
  return t;
}

mrb_value vp_set_tone_body(mrb_state* M, mrb_value self, mrb_value t);

mrb_value vp_set_tone_native_body(mrb_state* M, mrb_value self, mrb_value t) {
  return vp_set_tone_body(M, self, t);
}

mrb_value vp_set_tone(mrb_state* M, mrb_value self) {
  mrb_value t;
  mrb_get_args(M, "o", &t);
  return vp_set_tone_native_body(M, self, t);
}

mrb_value vp_set_tone_body(mrb_state* M, mrb_value self, mrb_value t) {
  mrb_iv_set(M, self, MRB_IVSYM(tone), t);
  vp_sync_tone(M, self);
  return t;
}

mrb_value vp_color(mrb_state* M, mrb_value self) {
  mrb_value c = mrb_iv_get(M, self, MRB_IVSYM(color));
  if (mrb_nil_p(c)) {
    const mrb_value args[] = {mrb_fixnum_value(0), mrb_fixnum_value(0),
                              mrb_fixnum_value(0), mrb_fixnum_value(0)};
    c = mrb_obj_new(M,
                    mrb_class_get_under_id(
                        M, mrb_module_get_id(M, MRB_SYM(RGSS)), MRB_SYM(Color)),
                    4, args);
    mrb_iv_set(M, self, MRB_IVSYM(color), c);
  }
  return c;
}

mrb_value vp_set_color(mrb_state* M, mrb_value self) {
  mrb_value c;
  mrb_get_args(M, "o", &c);
  return rgss::viewport_color_set_direct(M, self, c);
}

// Viewport#flash(color, duration): show `color` over the viewport, fading out
// over `duration` frames of #update. A nil colour is RGSS's "empty" flash,
// which for a viewport means no overlay at all.
mrb_value vp_flash(mrb_state* M, mrb_value self) {
  mrb_value color;
  mrb_int duration;
  mrb_get_args(M, "oi", &color, &duration);
  return rgss::viewport_flash_direct(M, self, color, duration);
}

// One frame: advance a running flash and repaint the overlay from the current
// colour (which the scripts mutate in place).
mrb_value vp_update(mrb_state* M, mrb_value self) {
  const mrb_value count_v = mrb_iv_get(M, self, MRB_IVSYM(flash_count));
  if (mrb_fixnum_p(count_v) && mrb_fixnum(count_v) > 0)
    mrb_iv_set(M, self, MRB_IVSYM(flash_count),
               mrb_fixnum_value(mrb_fixnum(count_v) - 1));
  vp_refresh_overlay(M, self);
  // The tone is mutated in place by the scripts, so re-read it per frame; the
  // re-composite it triggers is skipped unless the value actually moved.
  vp_sync_tone(M, self);
  return mrb_nil_value();
}

static mrb_value rect_s_load_native_body(mrb_state* M,
                                         mrb_value self,
                                         const char* p,
                                         mrb_int len) {
  int32_t v[4] = {0, 0, 0, 0};
  std::memcpy(v, p, std::min<mrb_int>(len, sizeof(v)));
  return DataType<Rect>::make(M, mrb_class_ptr(self), v[0], v[1], v[2], v[3]);
}

static mrb_value rect_dump_native_body(mrb_state* M, mrb_value self) {
  Rect& r = DataType<Rect>::get(M, self);
  int32_t v[4] = {(int32_t)r.x, (int32_t)r.y, (int32_t)r.width,
                  (int32_t)r.height};
  return mrb_str_new(M, reinterpret_cast<const char*>(v), sizeof(v));
}

static mrb_value rect_to_s_native_body(mrb_state* M, mrb_value self) {
  Rect& r = DataType<Rect>::get(M, self);
  char buf[128];
  std::snprintf(buf, sizeof(buf), "(%d, %d, %d, %d)", (int)r.x, (int)r.y,
                (int)r.width, (int)r.height);
  return mrb_str_new_cstr(M, buf);
}

static mrb_value rect_eq_native_body(mrb_state* M,
                                     mrb_value self,
                                     mrb_value o) {
  if (!mrb_obj_is_kind_of(M, o, mrb_class(M, self)))
    return mrb_false_value();
  Rect& a = DataType<Rect>::get(M, self);
  Rect& b = DataType<Rect>::get(M, o);
  return mrb_bool_value(a.x == b.x && a.y == b.y && a.width == b.width &&
                        a.height == b.height);
}

static mrb_value rect_empty_native_body(mrb_state* M, mrb_value self) {
  DataType<Rect>::get(M, self) = Rect{0, 0, 0, 0};
  return self;
}

static mrb_value rect_init(mrb_state* M, mrb_value self) {
  if (mrb_get_argc(M) == 0) {
    DataType<Rect>::alloc_obj(M, self);
  } else {
    mrb_int x, y, w, h;
    mrb_get_args(M, "iiii", &x, &y, &w, &h);
    DataType<Rect>::alloc_obj(M, self, x, y, w, h);
  }
  return self;
}

static mrb_value rect_set(mrb_state* M, mrb_value self) {
  if (mrb_get_argc(M) == 1) {
    V o;
    mrb_get_args(M, "o", &o);
    DataType<Rect>::get(M, self) = DataType<Rect>::get(M, o);
  } else {
    mrb_int x, y, w, h;
    mrb_get_args(M, "iiii", &x, &y, &w, &h);
    DataType<Rect>::get(M, self) = Rect{x, y, w, h};
  }
  return self;
}

static mrb_value rect_x(mrb_state* M, mrb_value self) {
  return rgss::rect_x_direct(M, self);
}
static mrb_value rect_y(mrb_state* M, mrb_value self) {
  return rgss::rect_y_direct(M, self);
}
static mrb_value rect_width(mrb_state* M, mrb_value self) {
  return rgss::rect_width_direct(M, self);
}
static mrb_value rect_height(mrb_state* M, mrb_value self) {
  return rgss::rect_height_direct(M, self);
}

static mrb_value rect_set_x(mrb_state* M, mrb_value self) {
  mrb_int x;
  mrb_get_args(M, "i", &x);
  return rgss::rect_x_set_direct(M, self, x);
}
static mrb_value rect_set_y(mrb_state* M, mrb_value self) {
  mrb_int x;
  mrb_get_args(M, "i", &x);
  return rgss::rect_y_set_direct(M, self, x);
}
static mrb_value rect_set_width(mrb_state* M, mrb_value self) {
  mrb_int x;
  mrb_get_args(M, "i", &x);
  return rgss::rect_width_set_direct(M, self, x);
}
static mrb_value rect_set_height(mrb_state* M, mrb_value self) {
  mrb_int x;
  mrb_get_args(M, "i", &x);
  return rgss::rect_height_set_direct(M, self, x);
}

static mrb_value rect_eq(mrb_state* M, mrb_value self) {
  V o;
  mrb_get_args(M, "o", &o);
  return rect_eq_native_body(M, self, o);
}

static mrb_value rect_load(mrb_state* M, mrb_value self) {
  const char* p;
  mrb_int len;
  mrb_get_args(M, "s", &p, &len);
  return rect_s_load_native_body(M, self, p, len);
}

// Register the Rect class: accessors, comparison and Marshal hooks.
void define_rect(mrb_state* M, RClass* m) {
  RClass* rect = mrb_define_class_under(M, m, "Rect", M->object_class);
  MRB_SET_INSTANCE_TT(rect, MRB_TT_DATA);
  g_native_rect_class = rect;
#if !defined(WIO_TERMINAL)  // Rect#dup/#clone: unused on wio
  static constexpr mrb_func_t rect_initialize_copy_tmpl = data_init_copy<Rect>;
#endif  // !defined(WIO_TERMINAL)
#define MRB_MT_CLASS RGSS__Rect
  static const mrb_mt_entry rect_methods[] = {
      MRB_MT_ENTRY(rect_init, MRB_SYM(initialize),
                   MRB_ARGS_OPT(4) | MRB_MT_PRIVATE)  //
#if !defined(WIO_TERMINAL)  // Rect#dup/#clone: unused on wio
      MRB_MT_ENTRY(rect_initialize_copy_tmpl, MRB_SYM(initialize_copy),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
#endif                                                // !defined(WIO_TERMINAL)
      MRB_MT_ENTRY(rect_set, MRB_SYM(set),
                   MRB_ARGS_REQ(1) | MRB_ARGS_OPT(3))                        //
      MRB_MT_ENTRY(rect_x, MRB_SYM(x), MRB_ARGS_NONE())                      //
      MRB_MT_ENTRY(rect_y, MRB_SYM(y), MRB_ARGS_NONE())                      //
      MRB_MT_ENTRY(rect_width, MRB_SYM(width), MRB_ARGS_NONE())              //
      MRB_MT_ENTRY(rect_height, MRB_SYM(height), MRB_ARGS_NONE())            //
      MRB_MT_ENTRY(rect_set_x, MRB_SYM_E(x), MRB_ARGS_REQ(1))                //
      MRB_MT_ENTRY(rect_set_y, MRB_SYM_E(y), MRB_ARGS_REQ(1))                //
      MRB_MT_ENTRY(rect_set_width, MRB_SYM_E(width), MRB_ARGS_REQ(1))        //
      MRB_MT_ENTRY(rect_set_height, MRB_SYM_E(height), MRB_ARGS_REQ(1))      //
      MRB_MT_ENTRY(rect_eq, MRB_OPSYM(eq), MRB_ARGS_REQ(1))                  //
      MRB_MT_ENTRY(rect_empty_native_body, MRB_SYM(empty), MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(rect_to_s_native_body, MRB_SYM(to_s), MRB_ARGS_NONE())    //
      MRB_MT_ENTRY(rect_dump_native_body, MRB_SYM(_dump), MRB_ARGS_REQ(1))   //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, rect, rect_methods);
#define MRB_MT_CLASS RGSS__Rect_singleton
  static const mrb_mt_entry rect_class_methods[] = {
      MRB_MT_ENTRY(rect_load, MRB_SYM(_load), MRB_ARGS_REQ(1))  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(rect)),
                  rect_class_methods);
}

}  // namespace

// Table#[] and Table#[]= for bc2cpp's closed index helpers: the
// bodies of table_get and table_set with their arguments passed in, and the
// test for the receivers those methods answer.
extern "C" {
mrb_bool rgss_table_p(mrb_value v) {
  return mrb_data_p(v) && DATA_TYPE(v) == &DataType<Table>::data_type;
}

mrb_value rgss_table_aref_impl(mrb_state* M,
                               mrb_value self,
                               mrb_int x,
                               mrb_int y,
                               mrb_int z) {
  return table_get_impl(M, self, x, y, z);
}

mrb_value rgss_table_aset_impl(mrb_state* M,
                               mrb_value self,
                               mrb_int argc,
                               mrb_value a0,
                               mrb_value a1,
                               mrb_value a2,
                               mrb_value a3) {
  return table_set_impl(M, self, argc, a0, a1, a2, a3);
}
}

// Exported Bitmap pixel access (see include/rgss_bitmap.hxx). Defined at file
// scope but still able to reach the anonymous-namespace Bitmap/DataType above,
// which stay visible here within this translation unit.
namespace rgss {

uint8_t* bitmap_pixels(mrb_state* M, mrb_value v, int* w, int* h) {
  if (!mrb_data_p(v))
    return nullptr;
  void* p = mrb_data_check_get_ptr(M, v, &DataType<Bitmap>::data_type);
  if (!p)
    return nullptr;
  // `p` is the shared_ptr<Bitmap> box DataType<Bitmap> now stores (see that
  // struct's own comment), not a Bitmap* -- same double-indirection
  // DataType<Bitmap>::get itself does.
  Bitmap* b = reinterpret_cast<std::shared_ptr<Bitmap>*>(p)->get();
  if (w)
    *w = b->width;
  if (h)
    *h = b->height;
  // The caller writes through this pointer.
  promote_to_direct(*b);
  return b->buffer.data();
}

void bitmap_mark_dirty(mrb_state* M, mrb_value v) {
  if (!mrb_data_p(v))
    return;
  void* p = mrb_data_check_get_ptr(M, v, &DataType<Bitmap>::data_type);
  if (p)
    reinterpret_cast<std::shared_ptr<Bitmap>*>(p)->get()->dirty = true;
}

// bc2cpp's own direct-construct entry points (see include/
// rgss_construct.hxx and tools/bc2cpp/bc2cpp.rb's NATIVE_CONSTRUCT_
// TARGETS). Called directly in place of Class#new's own allocate+
// initialize dispatch when a compiled `.new` call site's receiver is
// provably one of these classes -- the runtime class-identity guard lives
// at the call site, against the matching `native_*_class` accessor
// below (a gem-init-captured RClass*, independent of whatever the
// constant table says right now, so a reassigned constant falls back to
// ordinary `mrb_funcall` rather than misconstructing).
//
// Unwrapped (native C++ typed) parameters, not mrb_value -- the
// generated call site does the same mrb_as_int/mrb_as_float unboxing
// mrb_get_args' own "i"/"f" format specifiers do internally (see
// compile_send's own comment), so a devirtualized `Tone.new(x)` still
// observes identical coercion and identical TypeError-raising to the
// ordinary #initialize dispatch it replaces. `klass` is the guarded
// `mrb_class_ptr(recv)` the call site already computed, passed straight
// through. (`:object`, Sprite's viewport, passes through as a plain
// `mrb_value` -- `spr_init`'s own "|o" never coerces or raises.)
//
// Rect has no clamping at all (plain ints, straight through).
// Color/Tone apply the exact same clamp255/clamp_signed255 calls their
// own #initialize (color_init/tone_init) already does -- not a second
// copy of that logic that could drift, just the same two free functions
// called again in the same field order.
mrb_value rect_new_direct(mrb_state* M,
                          RClass* klass,
                          mrb_int x,
                          mrb_int y,
                          mrb_int w,
                          mrb_int h) {
  return DataType<Rect>::make(M, klass, x, y, w, h);
}

mrb_value color_new_direct(mrb_state* M,
                           RClass* klass,
                           double r,
                           double g,
                           double b,
                           double a) {
  return DataType<Color>::make(M, klass, clamp255(r), clamp255(g), clamp255(b),
                               clamp255(a));
}

mrb_value tone_new_direct(mrb_state* M,
                          RClass* klass,
                          double r,
                          double g,
                          double b,
                          double gray) {
  return DataType<Tone>::make(M, klass, clamp_signed255(r), clamp_signed255(g),
                              clamp_signed255(b), clamp255(gray));
}

RClass* native_rect_class(void) {
  return g_native_rect_class;
}
RClass* native_color_class(void) {
  return g_native_color_class;
}
RClass* native_tone_class(void) {
  return g_native_tone_class;
}
RClass* native_sprite_class(void) {
  return g_native_sprite_class;
}
RClass* native_bitmap_class(void) {
  return g_native_bitmap_class;
}
RClass* native_table_class(void) {
  return g_native_table_class;
}
RClass* native_window_class(void) {
  return g_native_window_class;
}
RClass* native_viewport_class(void) {
  return g_native_viewport_class;
}
RClass* native_plane_class(void) {
  return g_native_plane_class;
}
RClass* native_tilemap_class(void) {
  return g_native_tilemap_class;
}

mrb_value bitmap_width_direct(mrb_state* M, mrb_value self) {
  return bmp_width(M, self);
}

mrb_value bitmap_rect_direct(mrb_state* M, mrb_value self) {
  return bmp_rect(M, self);
}

mrb_value bitmap_clear_direct(mrb_state* M, mrb_value self) {
  return bmp_clear(M, self);
}

mrb_value viewport_rect_direct(mrb_state* M, mrb_value self) {
  return vp_rect(M, self);
}

mrb_value bitmap_height_direct(mrb_state* M, mrb_value self) {
  return bmp_height(M, self);
}

mrb_value rect_x_direct(mrb_state* M, mrb_value self) {
  return mrb_fixnum_value(DataType<Rect>::get(M, self).x);
}

mrb_value rect_y_direct(mrb_state* M, mrb_value self) {
  return mrb_fixnum_value(DataType<Rect>::get(M, self).y);
}

mrb_value rect_width_direct(mrb_state* M, mrb_value self) {
  return mrb_fixnum_value(DataType<Rect>::get(M, self).width);
}

mrb_value rect_height_direct(mrb_state* M, mrb_value self) {
  return mrb_fixnum_value(DataType<Rect>::get(M, self).height);
}

mrb_value color_red_direct(mrb_state* M, mrb_value self) {
  return component_get<Color, &Color::red>(M, self);
}

mrb_value color_green_direct(mrb_state* M, mrb_value self) {
  return component_get<Color, &Color::green>(M, self);
}

mrb_value color_blue_direct(mrb_state* M, mrb_value self) {
  return component_get<Color, &Color::blue>(M, self);
}

mrb_value color_alpha_direct(mrb_state* M, mrb_value self) {
  return component_get<Color, &Color::alpha>(M, self);
}

mrb_value tone_red_direct(mrb_state* M, mrb_value self) {
  return component_get<Tone, &Tone::red>(M, self);
}

mrb_value tone_green_direct(mrb_state* M, mrb_value self) {
  return component_get<Tone, &Tone::green>(M, self);
}

mrb_value tone_blue_direct(mrb_state* M, mrb_value self) {
  return component_get<Tone, &Tone::blue>(M, self);
}

mrb_value tone_gray_direct(mrb_state* M, mrb_value self) {
  return component_get<Tone, &Tone::gray>(M, self);
}

mrb_value disposed_direct(mrb_state* M, mrb_value self) {
  return obj_disposed(M, self);
}

mrb_value visible_direct(mrb_state* M, mrb_value self) {
  return obj_visible(M, self);
}

mrb_value sprite_update_direct(mrb_state* M, mrb_value self) {
  return spr_update(M, self);
}

mrb_value viewport_update_direct(mrb_state* M, mrb_value self) {
  return vp_update(M, self);
}

mrb_value dispose_direct(mrb_state* M, mrb_value self) {
  return obj_dispose(M, self);
}

// bc2cpp's direct-construct entry point for `Sprite.new` /
// `Sprite.new(viewport)` (NATIVE_CONSTRUCT_TARGETS,
// include/rgss_construct.hxx): the same body as `spr_init`, but the viewport
// arrives pre-resolved and the object is allocated here (Class#new's own
// `self.allocate` step, which the direct path bypasses).
mrb_value sprite_new_direct(mrb_state* M, RClass* klass, mrb_value viewport) {
  mrb_value self = mrb_obj_value(mrb_obj_alloc(M, MRB_TT_DATA, klass));
  display_init(M, self, &sprite_type);
  gfx::Node* p = gfx::sprite_new(parent_object(M, viewport));
  wrap_node(M, self, p);
  register_zobj(M, self);
  mrb_iv_set(M, self, MRB_IVSYM(viewport), viewport);
  return self;
}

// Bitmap's own entry: only the 2-Integer-arg size shape
// (`Bitmap.new(w, h)`, ~105 real sites) -- the (`String`, ...) file-load
// shapes keep ordinary dispatch (see NATIVE_CONSTRUCT_TARGETS' own
// `type_guard` comment for how the call site picks). Reproduces
// `bmp_init_size`'s own body exactly (`mrb_get_args(M, "ii", ...)` then
// `alloc_obj(M, self, w, h, kPixelARGB8888)`), parameterized
// on the already-checked dimensions the same way the other entries
// parameterize on their own unboxed arguments. The Ruby-level
// `Bitmap#initialize(f, s)` dispatches to `_init_size` exactly when its
// first argument is not a String -- both Integer-tagged arguments prove
// that branch, so the direct call observes identical behavior including
// for negative/huge dimensions (whatever `alloc_obj` does with them,
// both paths do equally). `_begin_load`'s own global diagnostics are a
// String-branch-only affair, never touched here.
mrb_value bitmap_new_direct(mrb_state* M, RClass* klass, mrb_int w, mrb_int h) {
  return DataType<Bitmap>::make(M, klass, w, h, kPixelARGB8888, LazyPixels{});
}

mrb_value sprite_bitmap_set_direct(mrb_state* M,
                                   mrb_value self,
                                   mrb_value bitmap) {
  mrb_iv_set(M, self, MRB_IVSYM(bitmap), bitmap);
  gfx::Node* obj = obj_require(M, self);
  spr_bind_display(M, self, obj);
  return bitmap;
}

mrb_value bitmap_fill_rect_direct(mrb_state* M,
                                  mrb_value self,
                                  mrb_value x_value,
                                  mrb_value y_value,
                                  mrb_value w_value,
                                  mrb_value h_value,
                                  mrb_value color) {
  const mrb_int x = mrb_as_int(M, x_value);
  const mrb_int y = mrb_as_int(M, y_value);
  const mrb_int w = mrb_as_int(M, w_value);
  const mrb_int h = mrb_as_int(M, h_value);
  Bitmap& b = bmp_raw(M, self);
  fill_pixels(b, x, y, w, h, DataType<Color>::get(M, color));
  b.dirty = true;
  return self;
}

// `rc_fields` non-null stands in for `source_rect` (STACK_RECT).
static mrb_value blt_rect(mrb_state* M,
                          mrb_value self,
                          mrb_value x_value,
                          mrb_value y_value,
                          mrb_value source,
                          mrb_value source_rect,
                          const Rect* rc_fields,
                          mrb_value opacity_value,
                          mrb_bool opacity_given) {
  const mrb_int x = mrb_as_int(M, x_value);
  const mrb_int y = mrb_as_int(M, y_value);
  void* source_data = mrb_data_get_ptr(M, source, &DataType<Bitmap>::data_type);
  Bitmap& dst = bmp_raw(M, self);
  const Rect& rc = rc_fields ? *rc_fields : DataType<Rect>::get(M, source_rect);
  mrb_int opacity = opacity_given ? mrb_as_int(M, opacity_value) : 255;
  if (opacity < 0)
    opacity = 0;
  if (opacity > 255)
    opacity = 255;
  if (!dst.deferred ||
      !deferred_record(dst, bmp_require_shared(M, source_data), x, y, rc,
                       static_cast<int>(opacity), false))
    blt_pixels(bmp_self(M, self), bmp_require(M, source_data), x, y, rc,
               opacity);
  dst.dirty = true;
  return self;
}

mrb_value bitmap_blt_direct(mrb_state* M,
                            mrb_value self,
                            mrb_value x_value,
                            mrb_value y_value,
                            mrb_value source,
                            mrb_value source_rect,
                            mrb_value opacity_value,
                            mrb_bool opacity_given) {
  return blt_rect(M, self, x_value, y_value, source, source_rect, nullptr,
                  opacity_value, opacity_given);
}

static Rect rect_of(const RectFields& f) {
  Rect r;
  r.x = f.x;
  r.y = f.y;
  r.width = f.width;
  r.height = f.height;
  return r;
}

mrb_value bitmap_blt_rects_direct(mrb_state* M,
                                  mrb_value self,
                                  mrb_value x_value,
                                  mrb_value y_value,
                                  mrb_value source,
                                  const RectFields& source_rect,
                                  mrb_value opacity_value,
                                  mrb_bool opacity_given) {
  const Rect rc = rect_of(source_rect);
  return blt_rect(M, self, x_value, y_value, source, mrb_nil_value(), &rc,
                  opacity_value, opacity_given);
}

mrb_value bitmap_stretch_blt_rects_direct(mrb_state* M,
                                          mrb_value self,
                                          mrb_value destination_rect,
                                          const RectFields* destination_fields,
                                          mrb_value source,
                                          mrb_value source_rect,
                                          const RectFields* source_fields,
                                          mrb_value opacity,
                                          mrb_bool opacity_given) {
  void* source_data = mrb_data_get_ptr(M, source, &DataType<Bitmap>::data_type);
  Rect dr, sr;
  if (destination_fields)
    dr = rect_of(*destination_fields);
  if (source_fields)
    sr = rect_of(*source_fields);
  return stretch_blt_rects(M, self, destination_rect,
                           destination_fields ? &dr : nullptr, source_data,
                           source_rect, source_fields ? &sr : nullptr, opacity,
                           opacity_given);
}

mrb_value bitmap_copy_blt_rects_direct(mrb_state* M,
                                       mrb_value self,
                                       mrb_value x,
                                       mrb_value y,
                                       mrb_value source,
                                       const RectFields& source_rect) {
  mrb_int dx = mrb_as_int(M, x);
  mrb_int dy = mrb_as_int(M, y);
  void* source_data = mrb_data_get_ptr(M, source, &DataType<Bitmap>::data_type);
  const Rect rc = rect_of(source_rect);
  return copy_blt_rect(M, self, dx, dy, source_data, mrb_nil_value(), &rc);
}

mrb_value bitmap_stretch_blt_direct(mrb_state* M,
                                    mrb_value self,
                                    mrb_value destination_rect,
                                    mrb_value source,
                                    mrb_value source_rect,
                                    mrb_value opacity,
                                    mrb_bool opacity_given) {
  void* source_data = mrb_data_get_ptr(M, source, &DataType<Bitmap>::data_type);
  return bmp_stretch_blt_body(M, self, destination_rect, source_data,
                              source_rect, opacity, opacity_given);
}

mrb_value bitmap_draw_text_direct(mrb_state* M,
                                  mrb_value self,
                                  mrb_int argc,
                                  const mrb_value* argv) {
  mrb_int x, y, w, h, align = 0;
  mrb_value text;
  if (argc <= 3) {
    Rect& rect = DataType<Rect>::get(M, argv[0]);
    x = rect.x;
    y = rect.y;
    w = rect.width;
    h = rect.height;
    text = argv[1];
    if (argc == 3)
      align = mrb_as_int(M, argv[2]);
  } else {
    x = mrb_as_int(M, argv[0]);
    y = mrb_as_int(M, argv[1]);
    w = mrb_as_int(M, argv[2]);
    h = mrb_as_int(M, argv[3]);
    text = argv[4];
    if (argc == 6)
      align = mrb_as_int(M, argv[5]);
  }
  return bmp_draw_text_body(M, self, x, y, w, h, text, align);
}

mrb_value bitmap_copy_blt_direct(mrb_state* M,
                                 mrb_value self,
                                 mrb_value x,
                                 mrb_value y,
                                 mrb_value source,
                                 mrb_value source_rect) {
  mrb_int dx = mrb_as_int(M, x);
  mrb_int dy = mrb_as_int(M, y);
  void* source_data = mrb_data_get_ptr(M, source, &DataType<Bitmap>::data_type);
  return bmp_copy_blt_body(M, self, dx, dy, source_data, source_rect);
}

mrb_value bitmap_text_size_direct(mrb_state* M,
                                  mrb_value self,
                                  mrb_value text) {
  text = mrb_ensure_string_type(M, text);
  return bmp_text_size_body(M, self, RSTRING_PTR(text), RSTRING_LEN(text));
}

mrb_value sprite_opacity_set_direct(mrb_state* M,
                                    mrb_value self,
                                    mrb_value opacity) {
  return spr_set_opacity_body(M, self, mrb_as_int(M, opacity));
}

mrb_value sprite_tone_set_direct(mrb_state* M, mrb_value self, mrb_value tone) {
  return spr_set_tone_body(M, self, tone);
}

mrb_value viewport_tone_set_direct(mrb_state* M,
                                   mrb_value self,
                                   mrb_value tone) {
  return vp_set_tone_body(M, self, tone);
}

// Native setters/getters shared by the mrb_define_method bindings (which unpack
// mrb_get_args and forward here) and by bc2cpp's exact-class-guarded calls, so
// the two paths cannot drift. Arguments arrive already typed: the generated
// call site checks mrb_integer_p before calling an mrb_int entry point and
// otherwise dispatches, leaving the coercion and TypeError to the binding.
// Raising on a disposed receiver (obj_require) is unchanged.
mrb_value object_x_set_direct(mrb_state* M, mrb_value self, mrb_int x) {
  gfx::Node* obj = obj_require(M, self);
  // Same-value skip: render code repositions sprites every frame (the player
  // tracks the camera whether or not it moved) and LVGL's setter invalidates
  // without comparing. The mirrored ivar is authoritative -- every write
  // passes through here.
  mrb_value cur = mrb_iv_get(M, self, MRB_IVSYM(x));
  if (!mrb_fixnum_p(cur) || mrb_fixnum(cur) != x) {
    gfx::node_set_x(obj, x);
    mrb_iv_set(M, self, MRB_IVSYM(x), mrb_fixnum_value(x));
  }
  return self;
}

mrb_value object_y_set_direct(mrb_state* M, mrb_value self, mrb_int y) {
  gfx::Node* obj = obj_require(M, self);
  // Same-value skip, see object_x_set_direct.
  mrb_value cur = mrb_iv_get(M, self, MRB_IVSYM(y));
  if (!mrb_fixnum_p(cur) || mrb_fixnum(cur) != y) {
    gfx::node_set_y(obj, y);
    mrb_iv_set(M, self, MRB_IVSYM(y), mrb_fixnum_value(y));
  }
  return self;
}

mrb_value object_z_set_direct(mrb_state* M, mrb_value self, mrb_int z) {
  mrb_iv_set(M, self, MRB_IVSYM(z), mrb_fixnum_value(z));
  update_z(M);
  return self;
}

mrb_value object_visible_set_direct(mrb_state* M, mrb_value self, mrb_bool v) {
  gfx::Node* obj = obj_require(M, self);
  // Same-value skip, see object_x_set_direct: visibility is re-asserted every
  // frame by several draw paths (pictures, vehicles, the battle gate). An unset
  // ivar (fresh sprite) must apply: LVGL objects start visible, and nil here
  // means "never poked", not "hidden".
  mrb_value cur = mrb_iv_get(M, self, MRB_IVSYM(visible));
  if (mrb_nil_p(cur) || mrb_test(cur) != v) {
    if (v)
      gfx::node_set_hidden(obj, false);
    else
      gfx::node_set_hidden(obj, true);
    mrb_iv_set(M, self, MRB_IVSYM(visible), mrb_bool_value(v));
  }
  return self;
}

mrb_value sprite_color_set_direct(mrb_state* M, mrb_value self, mrb_value v) {
  mrb_iv_set(M, self, MRB_IVSYM(color), v);
  gfx::Node* obj = obj_require(M, self);
  spr_bind_display(M, self, obj);
  return v;
}

mrb_value sprite_flash_direct(mrb_state* M,
                              mrb_value self,
                              mrb_value color,
                              mrb_int duration) {
  mrb_iv_set(M, self, MRB_IVSYM(flash_color), color);
  mrb_iv_set(M, self, MRB_IVSYM(flash_duration), mrb_fixnum_value(duration));
  mrb_iv_set(M, self, MRB_IVSYM(flash_count), mrb_fixnum_value(duration));
  gfx::Node* obj = obj_require(M, self);
  spr_bind_display(M, self, obj);
  return mrb_nil_value();
}

mrb_value viewport_color_set_direct(mrb_state* M, mrb_value self, mrb_value c) {
  mrb_iv_set(M, self, MRB_IVSYM(color), c);
  vp_refresh_overlay(M, self);
  return c;
}

mrb_value viewport_flash_direct(mrb_state* M,
                                mrb_value self,
                                mrb_value color,
                                mrb_int duration) {
  mrb_iv_set(M, self, MRB_IVSYM(flash_color), color);
  mrb_iv_set(M, self, MRB_IVSYM(flash_duration), mrb_fixnum_value(duration));
  mrb_iv_set(M, self, MRB_IVSYM(flash_count),
             mrb_fixnum_value(mrb_nil_p(color) ? 0 : duration));
  vp_refresh_overlay(M, self);
  return mrb_nil_value();
}

mrb_value viewport_tone_direct(mrb_state* M, mrb_value self) {
  return vp_tone(M, self);
}

mrb_value viewport_color_direct(mrb_state* M, mrb_value self) {
  return vp_color(M, self);
}

mrb_value rect_x_set_direct(mrb_state* M, mrb_value self, mrb_int x) {
  return mrb_fixnum_value(DataType<Rect>::get(M, self).x = x);
}

mrb_value rect_y_set_direct(mrb_state* M, mrb_value self, mrb_int y) {
  return mrb_fixnum_value(DataType<Rect>::get(M, self).y = y);
}

mrb_value rect_width_set_direct(mrb_state* M, mrb_value self, mrb_int w) {
  return mrb_fixnum_value(DataType<Rect>::get(M, self).width = w);
}

mrb_value rect_height_set_direct(mrb_state* M, mrb_value self, mrb_int h) {
  return mrb_fixnum_value(DataType<Rect>::get(M, self).height = h);
}

#if !defined(WIO_TERMINAL)
// Window, Tilemap and Plane bodies exist only off wio.
mrb_value window_update_direct(mrb_state* M, mrb_value self) {
  return window_update(M, self);
}

mrb_value tilemap_dispose_direct(mrb_state* M, mrb_value self) {
  return tilemap_dispose(M, self);
}

mrb_value window_openness_set_direct(mrb_state* M,
                                     mrb_value self,
                                     mrb_value openness) {
  return window_set_openness_body(M, self, mrb_as_int(M, openness));
}

mrb_value window_tone_set_direct(mrb_state* M, mrb_value self, mrb_value tone) {
  return window_set_tone_body(M, self, tone);
}

mrb_value window_tone_direct(mrb_state* M, mrb_value self) {
  return window_tone(M, self);
}

mrb_value window_contents_set_direct(mrb_state* M,
                                     mrb_value self,
                                     mrb_value bmp) {
  mrb_iv_set(M, self, MRB_IVSYM(contents), bmp);
  window_refresh(M, self);
  return bmp;
}

mrb_value window_width_set_direct(mrb_state* M, mrb_value self, mrb_int v) {
  mrb_iv_set(M, self, MRB_IVSYM(width), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_height_set_direct(mrb_state* M, mrb_value self, mrb_int v) {
  mrb_iv_set(M, self, MRB_IVSYM(height), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_windowskin_set_direct(mrb_state* M,
                                       mrb_value self,
                                       mrb_value skin) {
  mrb_iv_set(M, self, MRB_IVSYM(windowskin), skin);
  window_refresh(M, self);
  return skin;
}

mrb_value window_cursor_rect_set_direct(mrb_state* M,
                                        mrb_value self,
                                        mrb_value rect) {
  mrb_iv_set(M, self, MRB_IVSYM(cursor_rect), rect);
  window_refresh(M, self);
  return rect;
}

mrb_value window_active_set_direct(mrb_state* M, mrb_value self, mrb_bool v) {
  mrb_iv_set(M, self, MRB_IVSYM(active), mrb_bool_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_pause_set_direct(mrb_state* M, mrb_value self, mrb_bool v) {
  mrb_iv_set(M, self, MRB_IVSYM(pause), mrb_bool_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value tilemap_z_set_direct(mrb_state* M, mrb_value self, mrb_int z) {
  mrb_iv_set(M, self, MRB_IVSYM(z), mrb_fixnum_value(z));
  const mrb_value above = mrb_iv_get(M, self, MRB_IVSYM(_tm_above_obj));
  if (mrb_test(above))
    mrb_iv_set(M, above, MRB_IVSYM(z), mrb_fixnum_value(z + TILEMAP_ABOVE_Z));
  update_z(M);
  return self;
}

mrb_value tilemap_visible_set_direct(mrb_state* M, mrb_value self, mrb_bool v) {
  gfx::Node* obj = obj_require(M, self);
  const mrb_value above = mrb_iv_get(M, self, MRB_IVSYM(_tm_above_obj));
  gfx::Node* al = mrb_test(above) ? display_node(above) : nullptr;
  if (v) {
    gfx::node_set_hidden(obj, false);
    if (al)
      gfx::node_set_hidden(al, false);
  } else {
    gfx::node_set_hidden(obj, true);
    if (al)
      gfx::node_set_hidden(al, true);
  }
  mrb_iv_set(M, self, MRB_IVSYM(visible), mrb_bool_value(v));
  return self;
}

mrb_value plane_color_set_direct(mrb_state* M, mrb_value self, mrb_value v) {
  mrb_iv_set(M, self, MRB_IVSYM(color), v);
  plane_retile(M, self);
  return v;
}
#else   // defined(WIO_TERMINAL)
// The classes are never instantiated on wio, so their exact-class guards are
// never true; these only satisfy the link of generated call sites.
static mrb_value compiled_out_direct(mrb_state* M, mrb_value self) {
  mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(NotImplementedError)),
             "%C is not compiled into the Wio Terminal build (ADR 0220)",
             mrb_obj_class(M, self));
  return self;
}

mrb_value window_update_direct(mrb_state* M, mrb_value self) {
  return compiled_out_direct(M, self);
}
mrb_value tilemap_dispose_direct(mrb_state* M, mrb_value self) {
  return compiled_out_direct(M, self);
}
mrb_value window_openness_set_direct(mrb_state* M, mrb_value self, mrb_value) {
  return compiled_out_direct(M, self);
}
mrb_value window_tone_set_direct(mrb_state* M, mrb_value self, mrb_value) {
  return compiled_out_direct(M, self);
}
mrb_value window_tone_direct(mrb_state* M, mrb_value self) {
  return compiled_out_direct(M, self);
}
mrb_value window_contents_set_direct(mrb_state* M, mrb_value self, mrb_value) {
  return compiled_out_direct(M, self);
}
mrb_value window_width_set_direct(mrb_state* M, mrb_value self, mrb_int) {
  return compiled_out_direct(M, self);
}
mrb_value window_height_set_direct(mrb_state* M, mrb_value self, mrb_int) {
  return compiled_out_direct(M, self);
}
mrb_value window_windowskin_set_direct(mrb_state* M,
                                       mrb_value self,
                                       mrb_value) {
  return compiled_out_direct(M, self);
}
mrb_value window_cursor_rect_set_direct(mrb_state* M,
                                        mrb_value self,
                                        mrb_value) {
  return compiled_out_direct(M, self);
}
mrb_value window_active_set_direct(mrb_state* M, mrb_value self, mrb_bool) {
  return compiled_out_direct(M, self);
}
mrb_value window_pause_set_direct(mrb_state* M, mrb_value self, mrb_bool) {
  return compiled_out_direct(M, self);
}
mrb_value tilemap_z_set_direct(mrb_state* M, mrb_value self, mrb_int) {
  return compiled_out_direct(M, self);
}
mrb_value tilemap_visible_set_direct(mrb_state* M, mrb_value self, mrb_bool) {
  return compiled_out_direct(M, self);
}
mrb_value plane_color_set_direct(mrb_state* M, mrb_value self, mrb_value) {
  return compiled_out_direct(M, self);
}
#endif  // !defined(WIO_TERMINAL)

mrb_value table_new_direct(mrb_state* M,
                           RClass* klass,
                           mrb_int argc,
                           mrb_int x,
                           mrb_int y,
                           mrb_int z) {
  auto table = DataType<Table>::make_owned(M, int32_t{1}, int32_t{0},
                                           int32_t{1}, int32_t{1});
  table_initialize_fields(*table, argc, x, y, z);
  return DataType<Table>::make_direct(M, klass, std::move(table));
}

}  // namespace rgss

// The port's display (rgss_set_display in the backend) is RGSS::_display.
void rgss::gfx::display_attached(mrb_state* M, Display* display) {
  mrb_assert(
      !mrb_const_defined(M, mrb_obj_value(mrb_module_get_id(M, MRB_SYM(RGSS))),
                         MRB_SYM(_display)));
  mrb_const_set(M, mrb_obj_value(mrb_module_get(M, "RGSS")),
                mrb_intern_lit(M, "_display"), mrb_cptr_value(M, display));
}

// RGSS.mouse_x / mouse_y / mouse_pressed? — the pointer state captured by the
// SDL backend (see input_bridge.cxx). Read by MV's TouchInput bridge.
static mrb_value mouse_x_m(mrb_state* M, mrb_value) {
  (void)M;
  return mrb_fixnum_value(rgss_mouse_x());
}
static mrb_value mouse_y_m(mrb_state* M, mrb_value) {
  (void)M;
  return mrb_fixnum_value(rgss_mouse_y());
}
static mrb_value mouse_pressed_m(mrb_state* M, mrb_value) {
  (void)M;
  return mrb_bool_value(rgss_mouse_pressed() != 0);
}

// Where a bridged log line was written: the Ruby file and line, or file =
// nullptr when the call stack cannot say.
struct ScriptLocation {
  const char* file;
  int line;
};

// True for a frame that only *carried* the message rather than writing it.
// RGSS::ErrorReport's tee (Tee#write / #puts / .record / .push, all of
// error_report.rb) sits between every logging site and this binding, and
// RGSS.warn_once / .warn_stub are the engine's own forwarders on top of it --
// stamping the log with any of them would just name the plumbing on every
// line, which is the same uselessness as naming log_bridge.cxx.
static bool log_forwarder_frame(mrb_state* M,
                                const mrb_callinfo* ci,
                                const char* file) {
  const char* base = file;
  for (const char* p = file; *p != '\0'; ++p) {
    if (*p == '/' || *p == '\\')
      base = p + 1;
  }
  if (std::strcmp(base, "error_report.rb") == 0)
    return true;
  if (ci->mid == 0)
    return false;
  const char* mid = mrb_sym_name(M, ci->mid);
  return mid != nullptr && (std::strcmp(mid, "warn_once") == 0 ||
                            std::strcmp(mid, "warn_stub") == 0);
}

// The script location the innermost non-forwarder Ruby frame is at. Walks the
// interpreter's call stack the way mruby's own backtrace does (see
// pack_backtrace in 3rd/mruby/src/backtrace.c): each frame's proc carries the
// irep it runs, and the irep's debug info maps the frame's program counter to
// a file and line. Frames with no debug info are skipped rather than reported
// as unknown, so a build compiled without -g (or a C function in the middle of
// the stack) falls back to the next frame that can answer, and only a stack
// that can answer nowhere gives up.
static bool script_location(mrb_state* M, ScriptLocation* out) {
  for (const mrb_callinfo* ci = M->c->ci; ci >= M->c->cibase; --ci) {
    const struct RProc* proc = ci->proc;
    if (proc == nullptr || MRB_PROC_CFUNC_P(proc))
      continue;
    const mrb_irep* irep = proc->body.irep;
    if (irep == nullptr || ci->pc == nullptr)
      continue;
    // ci->pc is the *next* instruction to run, so the call being made is the
    // one before it -- the same -1 mruby's backtrace applies.
    const uint32_t idx = static_cast<uint32_t>(ci->pc - 1 - irep->iseq);
    int32_t line = -1;
    const char* file = nullptr;
    if (!mrb_debug_get_position(M, irep, idx, &line, &file))
      continue;
    if (file == nullptr || line < 0)
      continue;
    if (log_forwarder_frame(M, ci, file))
      continue;
    out->file = file;
    out->line = static_cast<int>(line);
    return true;
  }
  out->file = nullptr;
  out->line = 0;
  return false;
}

// RGSS.__log_bridge_write(line) -- called by RGSS::ErrorReport.push
// (mruby-rgss/mrblib/error_report.rb) for every $stderr line it buffers. See
// include/terminal.hxx's "Stderr log bridge" section.
//
// The line is forwarded together with the script location it was written at,
// so the engine's log names the script that logged ("Scene_Map:120") instead
// of stamping every bridged line with this bridge's own C++ call site. Returns
// that location as "file:line", or nil when the stack could not say -- what
// RGSS::ErrorReport.last_location exposes, and what the mrbtest build (which
// installs no hook, so nothing else about the forward is observable) checks.
static mrb_value log_bridge_write_m(mrb_state* M, mrb_value) {
  const char* msg;
  mrb_int len;
  mrb_get_args(M, "s", &msg, &len);
  ScriptLocation loc = {nullptr, 0};
  script_location(M, &loc);
  log_bridge_write(msg, static_cast<size_t>(len), loc.file, loc.line);
  if (loc.file == nullptr)
    return mrb_nil_value();
  return mrb_format(M, "%s:%d", loc.file, loc.line);
}

// RGSS.window_title = "..." -- the running game's own title, set by each
// maker's boot once its database says what the game is called (see
// include/terminal.hxx's "Window title bridge" section). nil clears it back to
// the empty string rather than raising: a project with no title of its own is
// a normal state, not an error.
static mrb_value window_title_set_m_native_body(mrb_state* M,
                                                mrb_value,
                                                mrb_value title) {
  if (mrb_nil_p(title)) {
    window_title_set("");
    return mrb_nil_value();
  }
  const mrb_value str = mrb_obj_as_string(M, title);
  window_title_set(mrb_str_to_cstr(M, str));
  return title;
}

static mrb_value window_title_set_m(mrb_state* M, mrb_value self) {
  mrb_value title = mrb_nil_value();
  mrb_get_args(M, "o", &title);
  return window_title_set_m_native_body(M, self, title);
}

// RGSS.window_title -- the last title set, or nil when none was. Reads the
// gem's own record rather than the window, so it answers under every backend.
static mrb_value window_title_get_m(mrb_state* M, mrb_value) {
  const std::string& title = window_title_get();
  return title.empty() ? mrb_nil_value()
                       : mrb_str_new(M, title.data(), title.size());
}

#if defined(WIO_TERMINAL)
// RGSS::Tilemap / RGSS::Window on wio: fail loudly rather than
// hand back an object that never draws.
static mrb_value not_compiled_init(mrb_state* M, mrb_value self) {
  mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(NotImplementedError)),
             "%C is not compiled into the Wio Terminal build (ADR 0220)",
             mrb_obj_class(M, self));
  return self;
}
#endif

static mrb_value table_dim_native_body(mrb_state* M, mrb_value self) {
  return mrb_fixnum_value(DataType<Table>::get(M, self).dim);
}

static mrb_value table_zsize_native_body(mrb_state* M, mrb_value self) {
  return mrb_fixnum_value(DataType<Table>::get(M, self).zsize);
}

static mrb_value table_ysize_native_body(mrb_state* M, mrb_value self) {
  return mrb_fixnum_value(DataType<Table>::get(M, self).ysize);
}

static mrb_value table_xsize_native_body(mrb_state* M, mrb_value self) {
  return mrb_fixnum_value(DataType<Table>::get(M, self).xsize);
}

// BEGIN native-binding-split (ADR 0263, generated)
namespace rgss {

[[maybe_unused]] static mrb_value native_split_compiled_out(mrb_state* M,
                                                            mrb_value self) {
  mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(NotImplementedError)),
             "%C is not compiled into this build (ADR 0263)",
             mrb_obj_class(M, self));
  return self;
}

mrb_value bmp_begin_load_direct(mrb_state* M, mrb_value self) {
  return bmp_begin_load(M, self);
}

#if !defined(WIO_TERMINAL)
mrb_value bmp_blur_direct(mrb_state* M, mrb_value self) {
  return bmp_blur(M, self);
}
#else
mrb_value bmp_blur_direct(mrb_state* M, mrb_value self) {
  return native_split_compiled_out(M, self);
}
#endif

mrb_value bmp_decoder_ran_direct(mrb_state* M, mrb_value self) {
  return bmp_decoder_ran(M, self);
}

mrb_value bmp_init_size_direct(mrb_state* M,
                               mrb_value self,
                               mrb_int w,
                               mrb_int h) {
  return bmp_init_size_native_body(M, self, w, h);
}

mrb_value bmp_load_error_direct(mrb_state* M, mrb_value self) {
  return bmp_load_error(M, self);
}

#if !defined(WIO_TERMINAL)
mrb_value bmp_s_pixel_bytes_direct(mrb_state* M, mrb_value self) {
  return bmp_s_pixel_bytes(M, self);
}
#else
mrb_value bmp_s_pixel_bytes_direct(mrb_state* M, mrb_value self) {
  return native_split_compiled_out(M, self);
}
#endif

mrb_value bmp_stbi_error_direct(mrb_state* M, mrb_value self) {
  return bmp_stbi_error(M, self);
}

mrb_value bmp_text_size_direct(mrb_state* M,
                               mrb_value self,
                               const char* s,
                               mrb_int len) {
  return bmp_text_size_native_body(M, self, s, len);
}

mrb_value color_dump_direct(mrb_state* M, mrb_value self) {
  return color_dump(M, self);
}

mrb_value color_eq_direct(mrb_state* M, mrb_value self, mrb_value o) {
  return color_eq_native_body(M, self, o);
}

mrb_value color_load_direct(mrb_state* M,
                            mrb_value self,
                            const char* p,
                            mrb_int len) {
  return color_load_native_body(M, self, p, len);
}

mrb_value color_to_s_direct(mrb_state* M, mrb_value self) {
  return color_to_s(M, self);
}

mrb_value default_font_path_m_direct(mrb_state* M, mrb_value self) {
  return default_font_path_m(M, self);
}

#if !defined(WIO_TERMINAL)
mrb_value gfx_frame_reset_direct(mrb_state* M, mrb_value self) {
  return gfx_frame_reset(M, self);
}
#else
mrb_value gfx_frame_reset_direct(mrb_state* M, mrb_value self) {
  return native_split_compiled_out(M, self);
}
#endif

mrb_value gfx_snap_to_bitmap_direct(mrb_state* M, mrb_value self) {
  return gfx_snap_to_bitmap(M, self);
}

mrb_value input_push_direct(mrb_state* M,
                            mrb_value self,
                            mrb_int key,
                            mrb_bool press) {
  return input_push_native_body(M, self, key, press);
}

mrb_value mouse_pressed_m_direct(mrb_state* M, mrb_value self) {
  return mouse_pressed_m(M, self);
}

mrb_value mouse_x_m_direct(mrb_state* M, mrb_value self) {
  return mouse_x_m(M, self);
}

mrb_value mouse_y_m_direct(mrb_state* M, mrb_value self) {
  return mouse_y_m(M, self);
}

#if !defined(WIO_TERMINAL)
mrb_value plane_set_bmp_direct(mrb_state* M, mrb_value self, mrb_value bmp) {
  return plane_set_bmp_native_body(M, self, bmp);
}
#else
mrb_value plane_set_bmp_direct(mrb_state* M, mrb_value self, mrb_value) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value plane_set_ox_direct(mrb_state* M, mrb_value self, mrb_int ox) {
  return plane_set_ox_native_body(M, self, ox);
}
#else
mrb_value plane_set_ox_direct(mrb_state* M, mrb_value self, mrb_int) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value plane_set_oy_direct(mrb_state* M, mrb_value self, mrb_int oy) {
  return plane_set_oy_native_body(M, self, oy);
}
#else
mrb_value plane_set_oy_direct(mrb_state* M, mrb_value self, mrb_int) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value plane_set_tone_direct(mrb_state* M, mrb_value self, mrb_value v) {
  return plane_set_tone_native_body(M, self, v);
}
#else
mrb_value plane_set_tone_direct(mrb_state* M, mrb_value self, mrb_value) {
  return native_split_compiled_out(M, self);
}
#endif

mrb_value rect_dump_direct(mrb_state* M, mrb_value self) {
  return rect_dump_native_body(M, self);
}

mrb_value rect_empty_direct(mrb_state* M, mrb_value self) {
  return rect_empty_native_body(M, self);
}

mrb_value rect_eq_direct(mrb_state* M, mrb_value self, mrb_value o) {
  return rect_eq_native_body(M, self, o);
}

mrb_value rect_s_load_direct(mrb_state* M,
                             mrb_value self,
                             const char* p,
                             mrb_int len) {
  return rect_s_load_native_body(M, self, p, len);
}

mrb_value rect_to_s_direct(mrb_state* M, mrb_value self) {
  return rect_to_s_native_body(M, self);
}

mrb_value spr_set_blend_type_direct(mrb_state* M, mrb_value self, mrb_int t) {
  return spr_set_blend_type_native_body(M, self, t);
}

mrb_value spr_set_bush_depth_direct(mrb_state* M, mrb_value self, mrb_int d) {
  return spr_set_bush_depth_native_body(M, self, d);
}

mrb_value spr_set_mirror_direct(mrb_state* M, mrb_value self, mrb_bool m) {
  return spr_set_mirror_native_body(M, self, m);
}

mrb_value spr_set_opacity_direct(mrb_state* M, mrb_value self, mrb_int opa) {
  return spr_set_opacity_native_body(M, self, opa);
}

mrb_value spr_set_src_rect_direct(mrb_state* M, mrb_value self, mrb_value v) {
  return spr_set_src_rect_native_body(M, self, v);
}

mrb_value spr_set_tone_direct(mrb_state* M, mrb_value self, mrb_value v) {
  return spr_set_tone_native_body(M, self, v);
}

mrb_value table_dim_direct(mrb_state* M, mrb_value self) {
  return table_dim_native_body(M, self);
}

mrb_value table_dump_direct(mrb_state* M, mrb_value self) {
  return table_dump(M, self);
}

mrb_value table_load_direct(mrb_state* M,
                            mrb_value self,
                            const char* p,
                            mrb_int len) {
  return table_load_native_body(M, self, p, len);
}

mrb_value table_xsize_direct(mrb_state* M, mrb_value self) {
  return table_xsize_native_body(M, self);
}

mrb_value table_ysize_direct(mrb_state* M, mrb_value self) {
  return table_ysize_native_body(M, self);
}

mrb_value table_zsize_direct(mrb_state* M, mrb_value self) {
  return table_zsize_native_body(M, self);
}

#if !defined(WIO_TERMINAL)
mrb_value tilemap_bitmaps_direct(mrb_state* M, mrb_value self) {
  return tilemap_bitmaps(M, self);
}
#else
mrb_value tilemap_bitmaps_direct(mrb_state* M, mrb_value self) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value tilemap_set_flags_direct(mrb_state* M, mrb_value self, mrb_value v) {
  return tilemap_set_flags_native_body(M, self, v);
}
#else
mrb_value tilemap_set_flags_direct(mrb_state* M, mrb_value self, mrb_value) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value tilemap_set_map_data_direct(mrb_state* M,
                                      mrb_value self,
                                      mrb_value v) {
  return tilemap_set_map_data_native_body(M, self, v);
}
#else
mrb_value tilemap_set_map_data_direct(mrb_state* M, mrb_value self, mrb_value) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value tilemap_set_ox_direct(mrb_state* M, mrb_value self, mrb_int v) {
  return tilemap_set_ox_native_body(M, self, v);
}
#else
mrb_value tilemap_set_ox_direct(mrb_state* M, mrb_value self, mrb_int) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value tilemap_set_oy_direct(mrb_state* M, mrb_value self, mrb_int v) {
  return tilemap_set_oy_native_body(M, self, v);
}
#else
mrb_value tilemap_set_oy_direct(mrb_state* M, mrb_value self, mrb_int) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value tilemap_set_priorities_direct(mrb_state* M,
                                        mrb_value self,
                                        mrb_value v) {
  return tilemap_set_priorities_native_body(M, self, v);
}
#else
mrb_value tilemap_set_priorities_direct(mrb_state* M,
                                        mrb_value self,
                                        mrb_value) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value tilemap_set_tileset_direct(mrb_state* M,
                                     mrb_value self,
                                     mrb_value v) {
  return tilemap_set_tileset_native_body(M, self, v);
}
#else
mrb_value tilemap_set_tileset_direct(mrb_state* M, mrb_value self, mrb_value) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value tilemap_update_direct(mrb_state* M, mrb_value self) {
  return tilemap_update(M, self);
}
#else
mrb_value tilemap_update_direct(mrb_state* M, mrb_value self) {
  return native_split_compiled_out(M, self);
}
#endif

#if (!defined(WIO_TERMINAL)) && (!defined(WIO_TERMINAL))
mrb_value tilemap_vx_table_leg_quads_direct(mrb_state* M,
                                            mrb_value self,
                                            mrb_int tile_id) {
  return tilemap_vx_table_leg_quads_native_body(M, self, tile_id);
}
#else
mrb_value tilemap_vx_table_leg_quads_direct(mrb_state* M,
                                            mrb_value self,
                                            mrb_int) {
  return native_split_compiled_out(M, self);
}
#endif

mrb_value tone_dump_direct(mrb_state* M, mrb_value self) {
  return tone_dump(M, self);
}

mrb_value tone_eq_direct(mrb_state* M, mrb_value self, mrb_value o) {
  return tone_eq_native_body(M, self, o);
}

mrb_value tone_load_direct(mrb_state* M,
                           mrb_value self,
                           const char* p,
                           mrb_int len) {
  return tone_load_native_body(M, self, p, len);
}

mrb_value tone_to_s_direct(mrb_state* M, mrb_value self) {
  return tone_to_s(M, self);
}

mrb_value vp_ox_direct(mrb_state* M, mrb_value self) {
  return vp_ox(M, self);
}

mrb_value vp_oy_direct(mrb_state* M, mrb_value self) {
  return vp_oy(M, self);
}

mrb_value vp_set_ox_direct(mrb_state* M, mrb_value self, mrb_int v) {
  return vp_set_ox_native_body(M, self, v);
}

mrb_value vp_set_oy_direct(mrb_state* M, mrb_value self, mrb_int v) {
  return vp_set_oy_native_body(M, self, v);
}

mrb_value vp_set_rect_direct(mrb_state* M, mrb_value self, mrb_value rv) {
  return vp_set_rect_native_body(M, self, rv);
}

mrb_value vp_set_tone_direct(mrb_state* M, mrb_value self, mrb_value t) {
  return vp_set_tone_native_body(M, self, t);
}

#if !defined(WIO_TERMINAL)
mrb_value window_set_back_opacity_direct(mrb_state* M,
                                         mrb_value self,
                                         mrb_int v) {
  return window_set_back_opacity_native_body(M, self, v);
}
#else
mrb_value window_set_back_opacity_direct(mrb_state* M,
                                         mrb_value self,
                                         mrb_int) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value window_set_contents_opacity_direct(mrb_state* M,
                                             mrb_value self,
                                             mrb_int v) {
  return window_set_contents_opacity_native_body(M, self, v);
}
#else
mrb_value window_set_contents_opacity_direct(mrb_state* M,
                                             mrb_value self,
                                             mrb_int) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value window_set_opacity_direct(mrb_state* M, mrb_value self, mrb_int v) {
  return window_set_opacity_native_body(M, self, v);
}
#else
mrb_value window_set_opacity_direct(mrb_state* M, mrb_value self, mrb_int) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value window_set_openness_direct(mrb_state* M, mrb_value self, mrb_int v) {
  return window_set_openness_native_body(M, self, v);
}
#else
mrb_value window_set_openness_direct(mrb_state* M, mrb_value self, mrb_int) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value window_set_ox_direct(mrb_state* M, mrb_value self, mrb_int v) {
  return window_set_ox_native_body(M, self, v);
}
#else
mrb_value window_set_ox_direct(mrb_state* M, mrb_value self, mrb_int) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value window_set_oy_direct(mrb_state* M, mrb_value self, mrb_int v) {
  return window_set_oy_native_body(M, self, v);
}
#else
mrb_value window_set_oy_direct(mrb_state* M, mrb_value self, mrb_int) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value window_set_stretch_direct(mrb_state* M, mrb_value self, mrb_bool v) {
  return window_set_stretch_native_body(M, self, v);
}
#else
mrb_value window_set_stretch_direct(mrb_state* M, mrb_value self, mrb_bool) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value window_set_tone_direct(mrb_state* M, mrb_value self, mrb_value t) {
  return window_set_tone_native_body(M, self, t);
}
#else
mrb_value window_set_tone_direct(mrb_state* M, mrb_value self, mrb_value) {
  return native_split_compiled_out(M, self);
}
#endif

#if !defined(WIO_TERMINAL)
mrb_value window_set_viewport_direct(mrb_state* M,
                                     mrb_value self,
                                     mrb_value vp) {
  return window_set_viewport_native_body(M, self, vp);
}
#else
mrb_value window_set_viewport_direct(mrb_state* M, mrb_value self, mrb_value) {
  return native_split_compiled_out(M, self);
}
#endif

mrb_value window_title_get_m_direct(mrb_state* M, mrb_value self) {
  return window_title_get_m(M, self);
}

mrb_value window_title_set_m_direct(mrb_state* M,
                                    mrb_value self,
                                    mrb_value title) {
  return window_title_set_m_native_body(M, self, title);
}

#if !defined(WIO_TERMINAL)
mrb_value zlib_inflate_direct(mrb_state* M,
                              mrb_value self,
                              const char* ptr,
                              mrb_int len) {
  return zlib_inflate_native_body(M, self, ptr, len);
}
#else
mrb_value zlib_inflate_direct(mrb_state* M,
                              mrb_value self,
                              const char*,
                              mrb_int) {
  return native_split_compiled_out(M, self);
}
#endif

}  // namespace rgss
// END native-binding-split

#ifdef MRB_VM_FREE
// Closed (VM-free) build: Class.new has no engine caller. Warn on each call to
// measure whether anything reaches it, then run the original.
static mrb_func_t class_new_orig;
static mrb_value class_new_warn(mrb_state* M, mrb_value self) {
  fprintf(stderr,
          "[RGSS] warning: Class.new called at runtime in the closed build\n");
  return class_new_orig(M, self);
}
#endif

// Array#_rgss_native_sort! is the core sort! as it stands before mrblib
// installs the comparator-normalizing wrapper. A row calling the captured C
// function is what the alias of that C method copied: same function, same
// receiver and block, no heap method entry.
static mrb_func_t native_sort_orig;
static mrb_value native_sort_bang(mrb_state* M, mrb_value self) {
  return native_sort_orig(M, self);
}

extern "C" void mrb_mruby_rgss_gem_init(mrb_state* M) {
  g_pixel_mrb = M;
  g_pixel_gc_base = pixel_bytes_live();
  mrb_method_t sort_bang =
      mrb_method_search(M, M->array_class, MRB_SYM_B(sort));
  if (!MRB_METHOD_FUNC_P(sort_bang)) {
    mrb_raise(M, mrb_exc_get_id(M, MRB_SYM(RuntimeError)),
              "Array#sort! is not a C function");
  }
  native_sort_orig = MRB_METHOD_FUNC(sort_bang);
#define MRB_MT_CLASS Array
  static const mrb_mt_entry array_methods[] = {
      MRB_MT_ENTRY(native_sort_bang, MRB_SYM_B(_rgss_native_sort),
                   MRB_ARGS_NONE())  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, M->array_class, array_methods);
#ifdef MRB_VM_FREE
  // The metaclass of Class holds the core Class.new. A singleton-class call
  // here would mark this file a singleton maker
  // (ClosedWorld::NATIVE_SINGLETON).
  mrb_method_t class_new =
      mrb_method_search(M, M->class_class->c, MRB_SYM(new));
  if (MRB_METHOD_FUNC_P(class_new)) {
    class_new_orig = MRB_METHOD_FUNC(class_new);
    // A run-time registration, not a row: the closed world's owner map reads
    // this call as Class.singleton#new, and a ROM table installed into the
    // metaclass names no class it can resolve.
    mrb_define_class_method(M, M->class_class, "new", class_new_warn,
                            MRB_ARGS_ANY());
  }
#endif
  RClass* m = mrb_define_module(M, "RGSS");
#define MRB_MT_CLASS RGSS_singleton
  static const mrb_mt_entry m_module_functions[] = {
      MRB_MT_ENTRY(to_nfd, MRB_SYM(to_nfd), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(default_font_path_m, MRB_SYM(default_font_path),
                   MRB_ARGS_NONE())  //
#if !defined(WIO_TERMINAL)           // unused on wio
      MRB_MT_ENTRY(zlib_inflate, MRB_SYM(zlib_inflate), MRB_ARGS_REQ(1))  //
#endif  // !defined(WIO_TERMINAL)
      MRB_MT_ENTRY(mouse_x_m, MRB_SYM(mouse_x), MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(mouse_y_m, MRB_SYM(mouse_y), MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(mouse_pressed_m, MRB_SYM_Q(mouse_pressed),
                   MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(log_bridge_write_m, MRB_SYM(__log_bridge_write),
                   MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(window_title_set_m, MRB_SYM_E(window_title),
                   MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(window_title_get_m, MRB_SYM(window_title),
                   MRB_ARGS_NONE())  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(m)),
                  m_module_functions);
#define MRB_MT_CLASS RGSS
  static const mrb_mt_entry m_module_functions_private[] = {
      MRB_MT_ENTRY(to_nfd, MRB_SYM(to_nfd),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(default_font_path_m, MRB_SYM(default_font_path),
                   MRB_ARGS_NONE() | MRB_MT_PRIVATE)  //
#if !defined(WIO_TERMINAL)                            // unused on wio
      MRB_MT_ENTRY(zlib_inflate, MRB_SYM(zlib_inflate),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
#endif                                                // !defined(WIO_TERMINAL)
      MRB_MT_ENTRY(mouse_x_m, MRB_SYM(mouse_x),
                   MRB_ARGS_NONE() | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(mouse_y_m, MRB_SYM(mouse_y),
                   MRB_ARGS_NONE() | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(mouse_pressed_m, MRB_SYM_Q(mouse_pressed),
                   MRB_ARGS_NONE() | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(log_bridge_write_m, MRB_SYM(__log_bridge_write),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(window_title_set_m, MRB_SYM_E(window_title),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(window_title_get_m, MRB_SYM(window_title),
                   MRB_ARGS_NONE() | MRB_MT_PRIVATE)  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, m, m_module_functions_private);

  mrb_const_set(M, mrb_obj_value(m), mrb_intern_lit(M, "_game_start"),
                mrb_fixnum_value(gfx::tick_ms()));
  mrb_const_set(M, mrb_obj_value(m), mrb_intern_lit(M, "_zobjs"),
                mrb_ary_new(M));

  RClass* vp = mrb_define_class_under(M, m, "Viewport", M->object_class);
  MRB_SET_INSTANCE_TT(vp, MRB_TT_DATA);
  g_native_viewport_class = vp;
#define MRB_MT_CLASS RGSS__Viewport
  static const mrb_mt_entry vp_methods[] = {
      MRB_MT_ENTRY(vp_init, MRB_SYM(initialize),
                   MRB_ARGS_OPT(4) | MRB_MT_PRIVATE)                      //
      MRB_MT_ENTRY(vp_rect, MRB_SYM(rect), MRB_ARGS_NONE())               //
      MRB_MT_ENTRY(vp_set_rect, MRB_SYM_E(rect), MRB_ARGS_REQ(1))         //
      MRB_MT_ENTRY(vp_ox, MRB_SYM(ox), MRB_ARGS_NONE())                   //
      MRB_MT_ENTRY(vp_oy, MRB_SYM(oy), MRB_ARGS_NONE())                   //
      MRB_MT_ENTRY(vp_set_ox, MRB_SYM_E(ox), MRB_ARGS_REQ(1))             //
      MRB_MT_ENTRY(vp_set_oy, MRB_SYM_E(oy), MRB_ARGS_REQ(1))             //
      MRB_MT_ENTRY(obj_set_z, MRB_SYM_E(z), MRB_ARGS_REQ(1))              //
      MRB_MT_ENTRY(obj_visible, MRB_SYM(visible), MRB_ARGS_NONE())        //
      MRB_MT_ENTRY(obj_set_visible, MRB_SYM_E(visible), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(vp_update, MRB_SYM(update), MRB_ARGS_NONE())           //
      // RGSS2/RGSS3 do every screen effect through the viewport: a flat colour
      // over everything it draws, and a timed flash. See vp_refresh_overlay.
      MRB_MT_ENTRY(vp_color, MRB_SYM(color), MRB_ARGS_NONE())           //
      MRB_MT_ENTRY(vp_set_color, MRB_SYM_E(color), MRB_ARGS_REQ(1))     //
      MRB_MT_ENTRY(vp_tone, MRB_SYM(tone), MRB_ARGS_NONE())             //
      MRB_MT_ENTRY(vp_set_tone, MRB_SYM_E(tone), MRB_ARGS_REQ(1))       //
      MRB_MT_ENTRY(vp_flash, MRB_SYM(flash), MRB_ARGS_REQ(2))           //
      MRB_MT_ENTRY(obj_dispose, MRB_SYM(dispose), MRB_ARGS_NONE())      //
      MRB_MT_ENTRY(obj_disposed, MRB_SYM_Q(disposed), MRB_ARGS_NONE())  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, vp, vp_methods);

  RClass* spr = mrb_define_class_under(M, m, "Sprite", M->object_class);
  MRB_SET_INSTANCE_TT(spr, MRB_TT_DATA);
  g_native_sprite_class = spr;
#define MRB_MT_CLASS RGSS__Sprite
  static const mrb_mt_entry spr_methods[] = {
      MRB_MT_ENTRY(spr_init, MRB_SYM(initialize),
                   MRB_ARGS_OPT(1) | MRB_MT_PRIVATE)                        //
      MRB_MT_ENTRY(spr_set_bmp, MRB_SYM_E(bitmap), MRB_ARGS_REQ(1))         //
      MRB_MT_ENTRY(obj_dispose, MRB_SYM(dispose), MRB_ARGS_NONE())          //
      MRB_MT_ENTRY(obj_disposed, MRB_SYM_Q(disposed), MRB_ARGS_NONE())      //
      MRB_MT_ENTRY(obj_set_x, MRB_SYM_E(x), MRB_ARGS_REQ(1))                //
      MRB_MT_ENTRY(obj_set_y, MRB_SYM_E(y), MRB_ARGS_REQ(1))                //
      MRB_MT_ENTRY(obj_set_z, MRB_SYM_E(z), MRB_ARGS_REQ(1))                //
      MRB_MT_ENTRY(obj_visible, MRB_SYM(visible), MRB_ARGS_NONE())          //
      MRB_MT_ENTRY(obj_set_visible, MRB_SYM_E(visible), MRB_ARGS_REQ(1))    //
      MRB_MT_ENTRY(spr_set_opacity, MRB_SYM_E(opacity), MRB_ARGS_REQ(1))    //
      MRB_MT_ENTRY(spr_set_zoom_x, MRB_SYM_E(zoom_x), MRB_ARGS_REQ(1))      //
      MRB_MT_ENTRY(spr_set_zoom_y, MRB_SYM_E(zoom_y), MRB_ARGS_REQ(1))      //
      MRB_MT_ENTRY(spr_set_angle, MRB_SYM_E(angle), MRB_ARGS_REQ(1))        //
      MRB_MT_ENTRY(spr_set_mirror, MRB_SYM_E(mirror), MRB_ARGS_REQ(1))      //
      MRB_MT_ENTRY(spr_set_tone, MRB_SYM_E(tone), MRB_ARGS_REQ(1))          //
      MRB_MT_ENTRY(spr_set_color, MRB_SYM_E(color), MRB_ARGS_REQ(1))        //
      MRB_MT_ENTRY(spr_set_src_rect, MRB_SYM_E(src_rect), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(spr_update, MRB_SYM(update), MRB_ARGS_NONE())            //
      MRB_MT_ENTRY(spr_set_blend_type, MRB_SYM_E(blend_type),
                   MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(spr_set_bush_depth, MRB_SYM_E(bush_depth),
                   MRB_ARGS_REQ(1))                             //
      MRB_MT_ENTRY(spr_flash, MRB_SYM(flash), MRB_ARGS_REQ(2))  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, spr, spr_methods);

#if !defined(WIO_TERMINAL)  // Plane: never instantiated by wio's Ruby
  RClass* plane = mrb_define_class_under(M, m, "Plane", M->object_class);
  g_native_plane_class = plane;
  MRB_SET_INSTANCE_TT(plane, MRB_TT_DATA);
#define MRB_MT_CLASS RGSS__Plane
  static const mrb_mt_entry plane_methods[] = {
      MRB_MT_ENTRY(plane_init, MRB_SYM(initialize),
                   MRB_ARGS_OPT(1) | MRB_MT_PRIVATE)                      //
      MRB_MT_ENTRY(plane_set_bmp, MRB_SYM_E(bitmap), MRB_ARGS_REQ(1))     //
      MRB_MT_ENTRY(plane_set_ox, MRB_SYM_E(ox), MRB_ARGS_REQ(1))          //
      MRB_MT_ENTRY(plane_set_oy, MRB_SYM_E(oy), MRB_ARGS_REQ(1))          //
      MRB_MT_ENTRY(spr_set_opacity, MRB_SYM_E(opacity), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(plane_set_tone, MRB_SYM_E(tone), MRB_ARGS_REQ(1))      //
      MRB_MT_ENTRY(plane_set_color, MRB_SYM_E(color), MRB_ARGS_REQ(1))    //
      MRB_MT_ENTRY(plane_set_zoom_x, MRB_SYM_E(zoom_x), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(plane_set_zoom_y, MRB_SYM_E(zoom_y), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(spr_set_blend_type, MRB_SYM_E(blend_type),
                   MRB_ARGS_REQ(1))                                       //
      MRB_MT_ENTRY(obj_set_z, MRB_SYM_E(z), MRB_ARGS_REQ(1))              //
      MRB_MT_ENTRY(obj_visible, MRB_SYM(visible), MRB_ARGS_NONE())        //
      MRB_MT_ENTRY(obj_set_visible, MRB_SYM_E(visible), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(obj_dispose, MRB_SYM(dispose), MRB_ARGS_NONE())        //
      MRB_MT_ENTRY(obj_disposed, MRB_SYM_Q(disposed), MRB_ARGS_NONE())    //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, plane, plane_methods);
#endif  // !defined(WIO_TERMINAL)

#if defined(WIO_TERMINAL)  // Tilemap is not compiled on wio
  {
    RClass* tilemap = mrb_define_class_under(M, m, "Tilemap", M->object_class);
#define MRB_MT_CLASS RGSS__Tilemap
    static const mrb_mt_entry tilemap_methods[] = {
        MRB_MT_ENTRY(not_compiled_init, MRB_SYM(initialize),
                     MRB_ARGS_ANY() | MRB_MT_PRIVATE)  //
    };
#undef MRB_MT_CLASS
    MRB_MT_INIT_ROM(M, tilemap, tilemap_methods);
    RClass* window = mrb_define_class_under(M, m, "Window", M->object_class);
#define MRB_MT_CLASS RGSS__Window
    static const mrb_mt_entry window_methods[] = {
        MRB_MT_ENTRY(not_compiled_init, MRB_SYM(initialize),
                     MRB_ARGS_ANY() | MRB_MT_PRIVATE)  //
    };
#undef MRB_MT_CLASS
    MRB_MT_INIT_ROM(M, window, window_methods);
  }
#else
  RClass* tilemap = mrb_define_class_under(M, m, "Tilemap", M->object_class);
  g_native_tilemap_class = tilemap;
  MRB_SET_INSTANCE_TT(tilemap, MRB_TT_DATA);
#define MRB_MT_CLASS RGSS__Tilemap
  static const mrb_mt_entry tilemap_methods[] = {
      MRB_MT_ENTRY(tilemap_init, MRB_SYM(initialize),
                   MRB_ARGS_OPT(1) | MRB_MT_PRIVATE)                          //
      MRB_MT_ENTRY(tilemap_set_tileset, MRB_SYM_E(tileset), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(tilemap_set_map_data, MRB_SYM_E(map_data),
                   MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(tilemap_set_priorities, MRB_SYM_E(priorities),
                   MRB_ARGS_REQ(1))  //
      // RGSS2 / RGSS3 (VX, VX Ace): nine sheets addressed by index plus the
      // tileset flags table, in place of XP's single tileset + autotiles +
      // priorities.
      MRB_MT_ENTRY(tilemap_bitmaps, MRB_SYM(bitmaps), MRB_ARGS_NONE())        //
      MRB_MT_ENTRY(tilemap_set_flags, MRB_SYM_E(flags), MRB_ARGS_REQ(1))      //
      MRB_MT_ENTRY(tilemap_set_ox, MRB_SYM_E(ox), MRB_ARGS_REQ(1))            //
      MRB_MT_ENTRY(tilemap_set_oy, MRB_SYM_E(oy), MRB_ARGS_REQ(1))            //
      MRB_MT_ENTRY(tilemap_update, MRB_SYM(update), MRB_ARGS_NONE())          //
      MRB_MT_ENTRY(tilemap_set_z, MRB_SYM_E(z), MRB_ARGS_REQ(1))              //
      MRB_MT_ENTRY(obj_visible, MRB_SYM(visible), MRB_ARGS_NONE())            //
      MRB_MT_ENTRY(tilemap_set_visible, MRB_SYM_E(visible), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(tilemap_dispose, MRB_SYM(dispose), MRB_ARGS_NONE())        //
      MRB_MT_ENTRY(obj_disposed, MRB_SYM_Q(disposed), MRB_ARGS_NONE())        //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, tilemap, tilemap_methods);
#define MRB_MT_CLASS RGSS__Tilemap_singleton
  static const mrb_mt_entry tilemap_class_methods[] = {
#if !defined(WIO_TERMINAL)  // VX-only tilemap rendering; wio ships no
                            // mruby-rpgvx
      MRB_MT_ENTRY(tilemap_vx_tile_quads, MRB_SYM(vx_tile_quads),
                   MRB_ARGS_ARG(1, 2))  //
      MRB_MT_ENTRY(tilemap_vx_table_leg_quads, MRB_SYM(vx_table_leg_quads),
                   MRB_ARGS_REQ(1))  //
#endif                      // !defined(WIO_TERMINAL)
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(tilemap)),
                  tilemap_class_methods);

  RClass* window = mrb_define_class_under(M, m, "Window", M->object_class);
  MRB_SET_INSTANCE_TT(window, MRB_TT_DATA);
  g_native_window_class = window;
#define MRB_MT_CLASS RGSS__Window
  static const mrb_mt_entry window_methods[] = {
      MRB_MT_ENTRY(window_init, MRB_SYM(initialize),
                   MRB_ARGS_OPT(1) | MRB_MT_PRIVATE)  //
      // The Ruby initializer delegates the RGSS1 viewport form here: the
      // alias of initialize, private as initialize is.
      MRB_MT_ENTRY(window_init, MRB_SYM(_rgss1_initialize),
                   MRB_ARGS_OPT(1) | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(window_set_contents, MRB_SYM_E(contents),
                   MRB_ARGS_REQ(1))                                        //
      MRB_MT_ENTRY(obj_set_x, MRB_SYM_E(x), MRB_ARGS_REQ(1))               //
      MRB_MT_ENTRY(obj_set_y, MRB_SYM_E(y), MRB_ARGS_REQ(1))               //
      MRB_MT_ENTRY(window_set_width, MRB_SYM_E(width), MRB_ARGS_REQ(1))    //
      MRB_MT_ENTRY(window_set_height, MRB_SYM_E(height), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(window_set_ox, MRB_SYM_E(ox), MRB_ARGS_REQ(1))          //
      MRB_MT_ENTRY(window_set_oy, MRB_SYM_E(oy), MRB_ARGS_REQ(1))          //
      MRB_MT_ENTRY(window_set_contents_opacity, MRB_SYM_E(contents_opacity),
                   MRB_ARGS_REQ(1))                                          //
      MRB_MT_ENTRY(window_set_skin, MRB_SYM_E(windowskin), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(window_set_opacity, MRB_SYM_E(opacity), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(window_set_back_opacity, MRB_SYM_E(back_opacity),
                   MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(window_set_cursor_rect, MRB_SYM_E(cursor_rect),
                   MRB_ARGS_REQ(1))                                          //
      MRB_MT_ENTRY(window_set_active, MRB_SYM_E(active), MRB_ARGS_REQ(1))    //
      MRB_MT_ENTRY(window_set_pause, MRB_SYM_E(pause), MRB_ARGS_REQ(1))      //
      MRB_MT_ENTRY(window_set_stretch, MRB_SYM_E(stretch), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(window_set_viewport, MRB_SYM_E(viewport),
                   MRB_ARGS_REQ(1))                                  //
      MRB_MT_ENTRY(window_update, MRB_SYM(update), MRB_ARGS_NONE())  //
      // RGSS2 / RGSS3 (VX, VX Ace): the open/close animation and the background
      // tone. Native because both have to redraw -- and so they must NOT be
      // redefined in mrblib, which loads after this and would shadow them.
      MRB_MT_ENTRY(window_set_openness, MRB_SYM_E(openness),
                   MRB_ARGS_REQ(1))                                       //
      MRB_MT_ENTRY(window_tone, MRB_SYM(tone), MRB_ARGS_NONE())           //
      MRB_MT_ENTRY(window_set_tone, MRB_SYM_E(tone), MRB_ARGS_REQ(1))     //
      MRB_MT_ENTRY(obj_set_z, MRB_SYM_E(z), MRB_ARGS_REQ(1))              //
      MRB_MT_ENTRY(obj_visible, MRB_SYM(visible), MRB_ARGS_NONE())        //
      MRB_MT_ENTRY(obj_set_visible, MRB_SYM_E(visible), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(obj_dispose, MRB_SYM(dispose), MRB_ARGS_NONE())        //
      MRB_MT_ENTRY(obj_disposed, MRB_SYM_Q(disposed), MRB_ARGS_NONE())    //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, window, window_methods);
#endif  // defined(WIO_TERMINAL)

  RClass* bmp = mrb_define_class_under(M, m, "Bitmap", M->object_class);
  MRB_SET_INSTANCE_TT(bmp, MRB_TT_DATA);
  g_native_bitmap_class = bmp;
#define MRB_MT_CLASS RGSS__Bitmap
  static const mrb_mt_entry bmp_methods[] = {
      MRB_MT_ENTRY(bmp_init_size, MRB_SYM(_init_size), MRB_ARGS_REQ(2))  //
      // Decode from bytes already in hand — how an asset packed into an
      // encrypted RGSSAD archive is loaded (mrblib/lib.rb's Bitmap#initialize
      // falls back to it when no loose file matches).
      MRB_MT_ENTRY(bmp_init_memory, MRB_SYM(_init_memory),
                   MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1))  //
      MRB_MT_ENTRY(bmp_init_file, MRB_SYM(_init_file),
                   MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1))  //
#if !defined(WIO_TERMINAL)
      // #clone / #dup: a real pixel copy, which RPG::Cache's hue variants need
      // -- an XP-only consumer (mruby-rpgxp), not shipped on wio; unused there.
      MRB_MT_ENTRY(bmp_init_copy, MRB_SYM(initialize_copy),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
#endif                                                // !defined(WIO_TERMINAL)
      // One frame of Graphics.transition's transition-graphic form; answers
      // false when this bitmap cannot carry the dissolve, so the caller can
      // plain-fade.
      MRB_MT_ENTRY(bmp_transition_alpha, MRB_SYM(_transition_alpha),
                   MRB_ARGS_REQ(3))                               //
      MRB_MT_ENTRY(bmp_width, MRB_SYM(width), MRB_ARGS_NONE())    //
      MRB_MT_ENTRY(bmp_height, MRB_SYM(height), MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(bmp_rect, MRB_SYM(rect), MRB_ARGS_NONE())      //
      MRB_MT_ENTRY(bmp_clear, MRB_SYM(clear), MRB_ARGS_NONE())    //
      MRB_MT_ENTRY(bmp_fill_rect, MRB_SYM(fill_rect),
                   MRB_ARGS_REQ(2) | MRB_ARGS_OPT(3))  //
#if !defined(WIO_TERMINAL)
      // gradient_fill_rect/hue_change/blur/radial_blur/set_pixel: RGSS2/RGSS3
      // Bitmap effects the stock XP/VX scripts use (title background, animation
      // effects, RPG::Cache hue variants) -- none of mruby-rpg2k's own Ruby
      // calls them, and wio ships no XP/VX/Wolf gem that would. Unused on wio.
      MRB_MT_ENTRY(bmp_gradient_fill_rect, MRB_SYM(gradient_fill_rect),
                   MRB_ARGS_REQ(3) | MRB_ARGS_OPT(4))                       //
      MRB_MT_ENTRY(bmp_hue_change, MRB_SYM(hue_change), MRB_ARGS_REQ(1))    //
      MRB_MT_ENTRY(bmp_blur, MRB_SYM(blur), MRB_ARGS_NONE())                //
      MRB_MT_ENTRY(bmp_radial_blur, MRB_SYM(radial_blur), MRB_ARGS_REQ(2))  //
#endif  // !defined(WIO_TERMINAL)
      MRB_MT_ENTRY(bmp_get_pixel, MRB_SYM(get_pixel), MRB_ARGS_REQ(2))  //
#if !defined(WIO_TERMINAL)
      MRB_MT_ENTRY(bmp_set_pixel, MRB_SYM(set_pixel), MRB_ARGS_REQ(3))  //
#endif  // !defined(WIO_TERMINAL)
      MRB_MT_ENTRY(bmp_blt, MRB_SYM(blt), MRB_ARGS_REQ(4) | MRB_ARGS_OPT(1))  //
      MRB_MT_ENTRY(bmp_blt_quads, MRB_SYM(blt_quads), MRB_ARGS_REQ(4))        //
      MRB_MT_ENTRY(bmp_tile_grid, MRB_SYM(tile_grid), MRB_ARGS_REQ(7))        //
      MRB_MT_ENTRY(bmp_copy_blt, MRB_SYM(copy_blt), MRB_ARGS_REQ(4))          //
      MRB_MT_ENTRY(bmp_defer, MRB_SYM(_defer), MRB_ARGS_OPT(1))               //
      MRB_MT_ENTRY(bmp_tone_blt, MRB_SYM(tone_blt), MRB_ARGS_REQ(2))          //
      MRB_MT_ENTRY(bmp_stretch_blt, MRB_SYM(stretch_blt),
                   MRB_ARGS_REQ(3) | MRB_ARGS_OPT(1))                     //
      MRB_MT_ENTRY(bmp_mosaic_blt, MRB_SYM(mosaic_blt), MRB_ARGS_REQ(2))  //
      MRB_MT_ENTRY(bmp_wave_blt, MRB_SYM(wave_blt), MRB_ARGS_REQ(3))      //
      // Both RGSS forms: (x, y, width, height, str[, align]) and (rect, str[,
      // align]).
      MRB_MT_ENTRY(bmp_draw_text, MRB_SYM(draw_text),
                   MRB_ARGS_REQ(2) | MRB_ARGS_OPT(4))  //
      MRB_MT_ENTRY(bmp_blend_text, MRB_SYM(blend_text),
                   MRB_ARGS_REQ(10) | MRB_ARGS_OPT(1))                  //
      MRB_MT_ENTRY(bmp_text_size, MRB_SYM(text_size), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(obj_dispose, MRB_SYM(dispose), MRB_ARGS_NONE())      //
      MRB_MT_ENTRY(obj_disposed, MRB_SYM_Q(disposed), MRB_ARGS_NONE())  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, bmp, bmp_methods);
#define MRB_MT_CLASS RGSS__Bitmap_singleton
  static const mrb_mt_entry bmp_class_methods[] = {
      MRB_MT_ENTRY(bmp_load_error, MRB_SYM(_load_error), MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(bmp_stbi_error, MRB_SYM(_stbi_error), MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(bmp_begin_load, MRB_SYM(_begin_load), MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(bmp_decoder_ran, MRB_SYM_Q(_decoder_ran),
                   MRB_ARGS_NONE())  //
#if !defined(WIO_TERMINAL)
      MRB_MT_ENTRY(bmp_s_pixel_bytes, MRB_SYM(_pixel_bytes),
                   MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(bmp_s_rom_bitmaps, MRB_SYM(_rom_bitmaps),
                   MRB_ARGS_REQ(2))  //
      MRB_MT_ENTRY(bmp_s_rom_bitmap_source, MRB_SYM(_rom_bitmap_source),
                   MRB_ARGS_REQ(3))  //
      MRB_MT_ENTRY(bmp_s_rom_bitmap_pins, MRB_SYM(_rom_bitmap_pins),
                   MRB_ARGS_NONE())  //
#endif
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(bmp)),
                  bmp_class_methods);

  RClass* color = mrb_define_class_under(M, m, "Color", M->object_class);
  MRB_SET_INSTANCE_TT(color, MRB_TT_DATA);
  g_native_color_class = color;
#if !defined(WIO_TERMINAL)
  static constexpr mrb_func_t color_initialize_copy_tmpl =
      data_init_copy<Color>;
#endif  // !defined(WIO_TERMINAL)
  static constexpr mrb_func_t color_red_get = component_get<Color, &Color::red>;
  static constexpr mrb_func_t color_red_set =
      component_set<Color, &Color::red, 0, 255>;
  static constexpr mrb_func_t color_green_get =
      component_get<Color, &Color::green>;
  static constexpr mrb_func_t color_green_set =
      component_set<Color, &Color::green, 0, 255>;
  static constexpr mrb_func_t color_blue_get =
      component_get<Color, &Color::blue>;
  static constexpr mrb_func_t color_blue_set =
      component_set<Color, &Color::blue, 0, 255>;
  static constexpr mrb_func_t color_alpha_get =
      component_get<Color, &Color::alpha>;
  static constexpr mrb_func_t color_alpha_set =
      component_set<Color, &Color::alpha, 0, 255>;
#define MRB_MT_CLASS RGSS__Color
  static const mrb_mt_entry color_methods[] = {
      MRB_MT_ENTRY(color_init, MRB_SYM(initialize),
                   MRB_ARGS_OPT(4) | MRB_MT_PRIVATE)  //
#if !defined(WIO_TERMINAL)
      // #clone / #dup, which a game's scripts use on these constantly --
      // checked against wio's own Ruby specifically: no real .dup/.clone target
      // is ever a Color there, so unused on wio.
      MRB_MT_ENTRY(color_initialize_copy_tmpl, MRB_SYM(initialize_copy),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
#endif                                                // !defined(WIO_TERMINAL)
      MRB_MT_ENTRY(color_set, MRB_SYM(set),
                   MRB_ARGS_REQ(1) | MRB_ARGS_OPT(3))                   //
      MRB_MT_ENTRY(color_eq, MRB_OPSYM(eq), MRB_ARGS_REQ(1))            //
      MRB_MT_ENTRY(color_to_s, MRB_SYM(to_s), MRB_ARGS_NONE())          //
      MRB_MT_ENTRY(color_dump, MRB_SYM(_dump), MRB_ARGS_REQ(1))         //
      MRB_MT_ENTRY(color_red_get, MRB_SYM(red), MRB_ARGS_NONE())        //
      MRB_MT_ENTRY(color_green_get, MRB_SYM(green), MRB_ARGS_NONE())    //
      MRB_MT_ENTRY(color_blue_get, MRB_SYM(blue), MRB_ARGS_NONE())      //
      MRB_MT_ENTRY(color_alpha_get, MRB_SYM(alpha), MRB_ARGS_NONE())    //
      MRB_MT_ENTRY(color_red_set, MRB_SYM_E(red), MRB_ARGS_REQ(1))      //
      MRB_MT_ENTRY(color_green_set, MRB_SYM_E(green), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(color_blue_set, MRB_SYM_E(blue), MRB_ARGS_REQ(1))    //
      MRB_MT_ENTRY(color_alpha_set, MRB_SYM_E(alpha), MRB_ARGS_REQ(1))  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, color, color_methods);
#define MRB_MT_CLASS RGSS__Color_singleton
  static const mrb_mt_entry color_class_methods[] = {
      MRB_MT_ENTRY(color_load, MRB_SYM(_load), MRB_ARGS_REQ(1))  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(color)),
                  color_class_methods);

  RClass* tone = mrb_define_class_under(M, m, "Tone", M->object_class);
  MRB_SET_INSTANCE_TT(tone, MRB_TT_DATA);
  g_native_tone_class = tone;
#if !defined(WIO_TERMINAL)  // Tone#dup/#clone: unused on wio
  static constexpr mrb_func_t tone_initialize_copy_tmpl = data_init_copy<Tone>;
#endif  // !defined(WIO_TERMINAL)
  static constexpr mrb_func_t tone_red_get = component_get<Tone, &Tone::red>;
  static constexpr mrb_func_t tone_red_set =
      component_set<Tone, &Tone::red, -255, 255>;
  static constexpr mrb_func_t tone_green_get =
      component_get<Tone, &Tone::green>;
  static constexpr mrb_func_t tone_green_set =
      component_set<Tone, &Tone::green, -255, 255>;
  static constexpr mrb_func_t tone_blue_get = component_get<Tone, &Tone::blue>;
  static constexpr mrb_func_t tone_blue_set =
      component_set<Tone, &Tone::blue, -255, 255>;
  static constexpr mrb_func_t tone_gray_get = component_get<Tone, &Tone::gray>;
#if !defined(WIO_TERMINAL)  // Tone#gray=: unused on wio
  static constexpr mrb_func_t tone_gray_set =
      component_set<Tone, &Tone::gray, 0, 255>;
#endif  // !defined(WIO_TERMINAL)
#define MRB_MT_CLASS RGSS__Tone
  static const mrb_mt_entry tone_methods[] = {
      MRB_MT_ENTRY(tone_init, MRB_SYM(initialize),
                   MRB_ARGS_OPT(4) | MRB_MT_PRIVATE)  //
#if !defined(WIO_TERMINAL)  // Tone#dup/#clone: unused on wio
      MRB_MT_ENTRY(tone_initialize_copy_tmpl, MRB_SYM(initialize_copy),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
#endif                                                // !defined(WIO_TERMINAL)
      MRB_MT_ENTRY(tone_set, MRB_SYM(set),
                   MRB_ARGS_REQ(1) | MRB_ARGS_OPT(3))                  //
      MRB_MT_ENTRY(tone_eq, MRB_OPSYM(eq), MRB_ARGS_REQ(1))            //
      MRB_MT_ENTRY(tone_to_s, MRB_SYM(to_s), MRB_ARGS_NONE())          //
      MRB_MT_ENTRY(tone_dump, MRB_SYM(_dump), MRB_ARGS_REQ(1))         //
      MRB_MT_ENTRY(tone_red_get, MRB_SYM(red), MRB_ARGS_NONE())        //
      MRB_MT_ENTRY(tone_green_get, MRB_SYM(green), MRB_ARGS_NONE())    //
      MRB_MT_ENTRY(tone_blue_get, MRB_SYM(blue), MRB_ARGS_NONE())      //
      MRB_MT_ENTRY(tone_gray_get, MRB_SYM(gray), MRB_ARGS_NONE())      //
      MRB_MT_ENTRY(tone_red_set, MRB_SYM_E(red), MRB_ARGS_REQ(1))      //
      MRB_MT_ENTRY(tone_green_set, MRB_SYM_E(green), MRB_ARGS_REQ(1))  //
      MRB_MT_ENTRY(tone_blue_set, MRB_SYM_E(blue), MRB_ARGS_REQ(1))    //
#if !defined(WIO_TERMINAL)  // Tone#gray=: unused on wio
      MRB_MT_ENTRY(tone_gray_set, MRB_SYM_E(gray), MRB_ARGS_REQ(1))  //
#endif  // !defined(WIO_TERMINAL)
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, tone, tone_methods);
#define MRB_MT_CLASS RGSS__Tone_singleton
  static const mrb_mt_entry tone_class_methods[] = {
      MRB_MT_ENTRY(tone_load, MRB_SYM(_load), MRB_ARGS_REQ(1))  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(tone)),
                  tone_class_methods);

  RClass* table = mrb_define_class_under(M, m, "Table", M->object_class);
  MRB_SET_INSTANCE_TT(table, MRB_TT_DATA);
  g_native_table_class = table;
#if !defined(WIO_TERMINAL)  // Table#dup/#clone: unused on wio
  static constexpr mrb_func_t table_initialize_copy_tmpl =
      data_init_copy<Table>;
#endif  // !defined(WIO_TERMINAL)
#define MRB_MT_CLASS RGSS__Table
  static const mrb_mt_entry table_methods[] = {
      MRB_MT_ENTRY(table_init, MRB_SYM(initialize),
                   MRB_ARGS_REQ(1) | MRB_ARGS_OPT(2) | MRB_MT_PRIVATE)  //
#if !defined(WIO_TERMINAL)  // Table#dup/#clone: unused on wio
      MRB_MT_ENTRY(table_initialize_copy_tmpl, MRB_SYM(initialize_copy),
                   MRB_ARGS_REQ(1) | MRB_MT_PRIVATE)  //
#endif                                                // !defined(WIO_TERMINAL)
      MRB_MT_ENTRY(table_get, MRB_OPSYM(aref),
                   MRB_ARGS_REQ(1) | MRB_ARGS_OPT(2))  //
      MRB_MT_ENTRY(table_set, MRB_OPSYM(aset),
                   MRB_ARGS_REQ(2) | MRB_ARGS_OPT(2))  //
      MRB_MT_ENTRY(table_resize, MRB_SYM(resize),
                   MRB_ARGS_REQ(1) | MRB_ARGS_OPT(2))                         //
      MRB_MT_ENTRY(table_xsize_native_body, MRB_SYM(xsize), MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(table_ysize_native_body, MRB_SYM(ysize), MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(table_zsize_native_body, MRB_SYM(zsize), MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(table_dim_native_body, MRB_SYM(dim), MRB_ARGS_NONE())      //
      MRB_MT_ENTRY(table_dump, MRB_SYM(_dump), MRB_ARGS_REQ(1))               //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, table, table_methods);
#define MRB_MT_CLASS RGSS__Table_singleton
  static const mrb_mt_entry table_class_methods[] = {
      MRB_MT_ENTRY(table_load, MRB_SYM(_load), MRB_ARGS_REQ(1))  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(table)),
                  table_class_methods);

  // RGSS::Input is otherwise pure Ruby (mrblib/lib.rb reopens this module); the
  // two native hooks are the backend drain Input.update calls and the test-side
  // push that stands in for a keyboard.
  RClass* input = mrb_define_module_under(M, m, "Input");
#define MRB_MT_CLASS RGSS__Input_singleton
  static const mrb_mt_entry input_module_functions[] = {
      MRB_MT_ENTRY(input_poll, MRB_SYM(_poll), MRB_ARGS_NONE())  //
      MRB_MT_ENTRY(input_push, MRB_SYM(_push), MRB_ARGS_REQ(2))  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(input)),
                  input_module_functions);
#define MRB_MT_CLASS RGSS__Input
  static const mrb_mt_entry input_module_functions_private[] = {
      MRB_MT_ENTRY(input_poll, MRB_SYM(_poll),
                   MRB_ARGS_NONE() | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(input_push, MRB_SYM(_push),
                   MRB_ARGS_REQ(2) | MRB_MT_PRIVATE)  //
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, input, input_module_functions_private);

  RClass* gfx = mrb_define_module_under(M, m, "Graphics");
#define MRB_MT_CLASS RGSS__Graphics_singleton
  static const mrb_mt_entry gfx_module_functions[] = {
      MRB_MT_ENTRY(gfx_update, MRB_SYM(update), MRB_ARGS_NONE())  //
      // RGSS2+: the rendered screen as a Bitmap. Graphics.freeze/transition are
      // built on it (mrblib/lib.rb), and RGSS.effect_probe measures with it.
      MRB_MT_ENTRY(gfx_snap_to_bitmap, MRB_SYM(snap_to_bitmap),
                   MRB_ARGS_NONE())  //
#if !defined(WIO_TERMINAL)           // unused on wio
      MRB_MT_ENTRY(gfx_frame_reset, MRB_SYM(frame_reset), MRB_ARGS_NONE())  //
#endif  // !defined(WIO_TERMINAL)
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, mrb_singleton_class_ptr(M, mrb_obj_value(gfx)),
                  gfx_module_functions);
#define MRB_MT_CLASS RGSS__Graphics
  static const mrb_mt_entry gfx_module_functions_private[] = {
      MRB_MT_ENTRY(gfx_update, MRB_SYM(update),
                   MRB_ARGS_NONE() | MRB_MT_PRIVATE)  //
      MRB_MT_ENTRY(gfx_snap_to_bitmap, MRB_SYM(snap_to_bitmap),
                   MRB_ARGS_NONE() | MRB_MT_PRIVATE)  //
#if !defined(WIO_TERMINAL)                            // unused on wio
      MRB_MT_ENTRY(gfx_frame_reset, MRB_SYM(frame_reset),
                   MRB_ARGS_NONE() | MRB_MT_PRIVATE)  //
#endif                                                // !defined(WIO_TERMINAL)
  };
#undef MRB_MT_CLASS
  MRB_MT_INIT_ROM(M, gfx, gfx_module_functions_private);

  profiler_init(M);

  rgss_audio_define(M, m);
  rgss_tts_define(M, m);

  define_rect(M, m);
}

extern "C" void mrb_mruby_rgss_gem_final(mrb_state* mrb) {
  // Flush and close a Chrome trace still open at shutdown (native path; the
  // Emscripten loop never returns, but the format tolerates the missing close).
  profiler_trace_stop();
  if (g_pixel_mrb == mrb)
    g_pixel_mrb = nullptr;
  // Defensive only (mrb_close frees every RClass this VM owns, so these
  // would-be-dangling pointers are never actually dereferenced by anything
  // reachable after this point) -- see g_native_*_class's own comment.
  g_native_rect_class = nullptr;
  g_native_color_class = nullptr;
  g_native_tone_class = nullptr;
  g_native_sprite_class = nullptr;
  g_native_bitmap_class = nullptr;
  g_native_table_class = nullptr;
  g_native_window_class = nullptr;
  g_native_viewport_class = nullptr;
  g_native_plane_class = nullptr;
  g_native_tilemap_class = nullptr;
}

// External names for the two dispose bodies that owner calls in other gems
// reach directly. obj_dispose and tilemap_dispose are internal (the anonymous
// namespace above), so these wrappers keep the registrations' behaviour: the
// same body under a name the generated code of another gem can declare.
// OwnerCallDirect (tools/bc2cpp/owner_call_direct.rb) names them;
// scripts/bc2cpp/owner_call_direct_native_check.rb holds them to the
// registrations.
mrb_value rgss_obj_dispose_direct(mrb_state* M, mrb_value self) {
  return obj_dispose(M, self);
}
#if !defined(WIO_TERMINAL)  // LOCAL MEASUREMENT GUARD, not committed
mrb_value rgss_tilemap_dispose_direct(mrb_state* M, mrb_value self) {
  return tilemap_dispose(M, self);
}
#endif  // LOCAL MEASUREMENT GUARD

// OWNER_CALL_DIRECT rows of the other natives an owner call reaches by name
// (NATIVE_ROWS in tools/bc2cpp/owner_call_direct.rb): the body of a ROM entry
// under an exported name, with the entry's own arity and visibility held by
// scripts/bc2cpp-rpg/owner_call_direct_native_check.rb.
#define OWNER_ROW(wrapper, body)                    \
  mrb_value wrapper(mrb_state* M, mrb_value self) { \
    return body(M, self);                           \
  }
OWNER_ROW(rgss_row_sprite_opacity_set, spr_set_opacity)
OWNER_ROW(rgss_row_bitmap_init_memory, bmp_init_memory)
OWNER_ROW(rgss_row_bitmap_init_file, bmp_init_file)
OWNER_ROW(rgss_row_bitmap_transition_alpha, bmp_transition_alpha)
OWNER_ROW(rgss_row_bitmap_get_pixel, bmp_get_pixel)
OWNER_ROW(rgss_row_bitmap_blt_quads, bmp_blt_quads)
OWNER_ROW(rgss_row_bitmap_tone_blt, bmp_tone_blt)
OWNER_ROW(rgss_row_bitmap_mosaic_blt, bmp_mosaic_blt)
OWNER_ROW(rgss_row_bitmap_wave_blt, bmp_wave_blt)
OWNER_ROW(rgss_row_bitmap_blend_text, bmp_blend_text)
OWNER_ROW(rgss_row_input_s_poll, input_poll)
OWNER_ROW(rgss_row_input_poll, input_poll)
#if !defined(WIO_TERMINAL)
OWNER_ROW(rgss_row_plane_opacity_set, spr_set_opacity)
OWNER_ROW(rgss_row_window_opacity_set, window_set_opacity)
OWNER_ROW(rgss_row_bitmap_hue_change, bmp_hue_change)
#else
// The rows above are registered on every target (owner_call_direct.rb), but
// their bodies are compiled out on wio, so the wio link needs a symbol for
// each. A call raises rather than doing nothing, so a game that reaches one
// sees why.
#define WIO_UNAVAILABLE_ROW(wrapper)                             \
  mrb_value wrapper(mrb_state* mrb, mrb_value) {                 \
    mrb_raise(mrb, E_RUNTIME_ERROR,                              \
              #wrapper " is not available on the Wio Terminal"); \
  }
WIO_UNAVAILABLE_ROW(rgss_row_plane_opacity_set)
WIO_UNAVAILABLE_ROW(rgss_row_window_opacity_set)
WIO_UNAVAILABLE_ROW(rgss_row_bitmap_hue_change)
#undef WIO_UNAVAILABLE_ROW
#endif
#undef OWNER_ROW
