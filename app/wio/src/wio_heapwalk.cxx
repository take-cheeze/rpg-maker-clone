// HEAPWALK: Renode-only heap snapshots for the wio_renode_game firmware
// (env:wio_renode_game_heapwalk, read by scripts/wio/heapwalk_report.rb).
//
// malloc/free/realloc/calloc replace newlib-nano's malloc.o, realloc.o and
// calloc.o and forward to the _r functions; every live block gets a shadow
// slot (requested size and up to kChain return addresses found on the stack)
// in memory the real board does not have (heapwalk.repl). A snapshot copies
// the live slots to the output window and calls heapwalk_flush, where a
// Renode hook saves that window and the whole heap to files. Snapshots are
// taken at each probe of wio_renode_game_main.cxx and whenever the live bytes
// pass the current scene's peak by kPeakStep, so the last peak file of a
// scene is its heap at (within kPeakStep of) its peak.
//
// newlib's own _malloc_r callers (stdio) are not seen: the report shows them
// as the difference to mallinfo.

#include <malloc.h>
#include <reent.h>

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/gc.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" char __end__;
extern "C" char __StackTop;
extern "C" void* _sbrk(ptrdiff_t);

namespace {

constexpr uintptr_t kShadowBase = 0x08000000;
constexpr size_t kShadowSize = 0x02000000;
constexpr uintptr_t kOutBase = 0x0A000000;
constexpr size_t kOutSize = 0x01000000;
constexpr int kChain = 12;
constexpr size_t kPeakStep = 2048;
constexpr uint32_t kPeakSlotBase = 1000;

struct Slot {
  uint32_t req_plus1;  // 0: no live block starts here
  uint32_t chain[kChain];
};
constexpr size_t kSlots = kShadowSize / sizeof(Slot);

struct Header {
  char magic[4];
  uint32_t slot, kind, frame;
  uint32_t live, inuse, sbrk_top, heap_base;
  uint32_t n_blocks, n_classes_bytes, stack_low, reserved;
  char name[64];
};

struct Record {
  uint32_t ptr, req, usable;
  uint32_t chain[kChain];
};

bool g_ready = true;
bool g_busy = false;  // inside a snapshot: its own allocations are not peaks
uint32_t g_live = 0;
uint32_t g_peak = 0;
uint32_t g_peak_slot = kPeakSlotBase;
uint32_t g_probe_slot = 0;
long g_frame_now = 0;
char g_scene_name[64] = "boot";
mrb_state* g_mrb = nullptr;

uintptr_t heap_base() {
  return (reinterpret_cast<uintptr_t>(&__end__) + 7) & ~uintptr_t{7};
}

Slot* slot_of(void* p) {
  const uintptr_t a = reinterpret_cast<uintptr_t>(p);
  const uintptr_t i = (a - heap_base()) / 8;
  if (a < heap_base() || i >= kSlots)
    return nullptr;
  return reinterpret_cast<Slot*>(kShadowBase) + i;
}

// A return address: odd, in code, and right after a BL, BLX imm or BLX Rm.
bool return_address_p(uint32_t v) {
  if (!(v & 1))
    return false;
  const uint32_t a = v & ~1u;
  if (!((a >= 0x4004 && a < 0x200000) || (a >= 0x04000004 && a < 0x04800000)))
    return false;
  const uint16_t* h = reinterpret_cast<const uint16_t*>(a);
  if ((h[-2] & 0xF800) == 0xF000 && (h[-1] & 0xC000) == 0xC000)
    return true;
  return (h[-1] & 0xFF87) == 0x4780;
}

__attribute__((noinline)) void note(void* p, size_t req, uint32_t lr) {
  Slot* s = slot_of(p);
  if (!s)
    return;
  s->req_plus1 = static_cast<uint32_t>(req) + 1;
  int n = 0;
  s->chain[n++] = lr;
  uint32_t* sp;
  __asm__ volatile("mov %0, sp" : "=r"(sp));
  const uint32_t* top = reinterpret_cast<const uint32_t*>(&__StackTop);
  for (const uint32_t* w = sp; w < top && w < sp + 768 && n < kChain; ++w)
    if (return_address_p(*w) && *w != lr)
      s->chain[n++] = *w;
  while (n < kChain)
    s->chain[n++] = 0;
  g_live += malloc_usable_size(p);
}

void forget(void* p) {
  Slot* s = slot_of(p);
  if (!s || !s->req_plus1)
    return;
  s->req_plus1 = 0;
  g_live -= malloc_usable_size(p);
}

}  // namespace

// Saves the output window [kOutBase, +out_len) and the heap [heap, +heap_len)
// as snapshot `slot` (the Renode hook does the saving).
extern "C" __attribute__((noinline, used)) void heapwalk_flush(
    uint32_t slot,
    uint32_t out_len,
    uint32_t heap,
    uint32_t heap_len) {
  __asm__ volatile(""
                   :
                   : "r"(slot), "r"(out_len), "r"(heap), "r"(heap_len)
                   : "memory");
}

namespace {

int class_names(mrb_state* mrb, RBasic* o, void* ud) {
  if (o->tt != MRB_TT_CLASS && o->tt != MRB_TT_MODULE)
    return MRB_EACH_OBJ_OK;
  char*& out = *static_cast<char**>(ud);
  const char* name = mrb_class_name(mrb, reinterpret_cast<RClass*>(o));
  if (!name)
    return MRB_EACH_OBJ_OK;
  const size_t room = kOutBase + kOutSize - reinterpret_cast<uintptr_t>(out);
  const size_t n = std::strlen(name);
  if (n + 16 > room)
    return MRB_EACH_OBJ_BREAK;
  out += std::snprintf(out, room, "%08x %s\n",
                       static_cast<unsigned>(reinterpret_cast<uintptr_t>(o)),
                       name);
  return MRB_EACH_OBJ_OK;
}

void snapshot(uint32_t slot, uint32_t kind, const char* name, bool classes) {
  g_busy = true;
  Header* h = reinterpret_cast<Header*>(kOutBase);
  std::memset(h, 0, sizeof(*h));
  std::memcpy(h->magic, "HWS1", 4);
  h->slot = slot;
  h->kind = kind;
  h->frame = static_cast<uint32_t>(g_frame_now);
  h->live = g_live;
  struct mallinfo mi = mallinfo();
  h->inuse = mi.uordblks;
  const uintptr_t top = reinterpret_cast<uintptr_t>(_sbrk(0));
  h->sbrk_top = top;
  h->heap_base = heap_base();
  std::strncpy(h->name, name, sizeof(h->name) - 1);
  Record* r = reinterpret_cast<Record*>(h + 1);
  const Slot* s = reinterpret_cast<const Slot*>(kShadowBase);
  const size_t n = (top - heap_base()) / 8;
  uint32_t blocks = 0;
  for (size_t i = 0; i < n && i < kSlots; ++i) {
    if (!s[i].req_plus1)
      continue;
    r->ptr = heap_base() + i * 8;
    r->req = s[i].req_plus1 - 1;
    r->usable = malloc_usable_size(reinterpret_cast<void*>(r->ptr));
    std::memcpy(r->chain, s[i].chain, sizeof(r->chain));
    ++r;
    ++blocks;
  }
  h->n_blocks = blocks;
  char* out = reinterpret_cast<char*>(r);
  // mrb_class_name's strings are left in the GC arena: kept there, those of a
  // boot snapshot would stay live for the whole run.
  if (classes && g_mrb) {
    const int ai = mrb_gc_arena_save(g_mrb);
    mrb_objspace_each_objects(g_mrb, class_names, &out);
    mrb_gc_arena_restore(g_mrb, ai);
  }
  h->n_classes_bytes = out - reinterpret_cast<char*>(r);
  heapwalk_flush(slot, out - reinterpret_cast<char*>(h), heap_base(),
                 top - heap_base());
  g_busy = false;
}

void maybe_peak() {
  if (!g_ready || g_busy || g_live < g_peak + kPeakStep)
    return;
  g_peak = g_live;
  char name[80];
  std::snprintf(name, sizeof(name), "peak:%s", g_scene_name);
  snapshot(g_peak_slot, 1, name, false);
}

}  // namespace

extern "C" {

void* malloc(size_t n) {
  void* p = _malloc_r(_REENT, n);
  if (p) {
    note(p, n, reinterpret_cast<uint32_t>(__builtin_return_address(0)));
    maybe_peak();
  }
  return p;
}

void free(void* p) {
  if (p)
    forget(p);
  _free_r(_REENT, p);
}

void* calloc(size_t n, size_t m) {
  void* p = _calloc_r(_REENT, n, m);
  if (p) {
    note(p, n * m, reinterpret_cast<uint32_t>(__builtin_return_address(0)));
    maybe_peak();
  }
  return p;
}

void* realloc(void* p, size_t n) {
  // nano's _realloc_r frees the old block itself (or returns it), so it is
  // forgotten first and noted again if it survives.
  if (p)
    forget(p);
  void* q = _realloc_r(_REENT, p, n);
  if (q) {
    note(q, n, reinterpret_cast<uint32_t>(__builtin_return_address(0)));
    maybe_peak();
  } else if (p && n) {
    note(p, malloc_usable_size(p),
         reinterpret_cast<uint32_t>(__builtin_return_address(0)));
  }
  return q;
}

// Called by wio_renode_game_main.cxx (weak there).
void wio_heapwalk_begin(mrb_state* mrb) {
  g_mrb = mrb;
  g_ready = true;
}

void wio_heapwalk_probe(const char* phase, long frame) {
  g_frame_now = frame;
  if (std::strncmp(phase, "scene:", 6) == 0) {
    std::strncpy(g_scene_name, phase + 6, sizeof(g_scene_name) - 1);
    ++g_peak_slot;
    g_peak = g_live;
  }
  snapshot(g_probe_slot++, 0, phase, true);
}

void wio_heapwalk_frame(long frame) {
  g_frame_now = frame;
}

}  // extern "C"
