// Work around a broken FDE sort in this pspdev toolchain's libgcc, which stops
// C++ exceptions from working at all on the PSP.
//
// Symptom: any `throw` -- including mruby's own, since gems shipping .cxx
// sources make mruby build with the C++ exception ABI (MRB_USE_CXX_EXCEPTION),
// so MRB_THROW is a real throw -- aborts inside libgcc's
// uw_init_context_1 (`unwind-dw2.c`, `gcc_assert (code == _URC_NO_REASON)`).
// That assert fires when uw_frame_state_for cannot find an FDE for the frame
// it is unwinding.
//
// Cause: the CFI itself is fine. `.eh_frame` is complete, correctly bracketed
// by __EH_FRAME_BEGIN__/__FRAME_END__, inside a PT_LOAD, and registered before
// main() by crt0 -> _init -> frame_dummy -> __register_frame_info. What fails
// is libgcc's own `fde_radixsort`: an 8-bit-digit radix sort that needs four
// passes to cover a 32-bit address, but whose output is exactly the state
// after two. Measured on this EBOOT: the array it produces has 1460 inversions
// against the full pc_begin, and *zero* against pc_begin & 0xffff -- perfectly
// sorted on the low halfword. Every code address here is 0x08xxxxxx, so
// ordering by the low halfword is meaningless, and the binary search in
// search_object misses every entry. Ruled out along the way: the CFI data,
// registration, __builtin_return_address, libgcc's packed unaligned read in
// unwind-pe.h, and memmove/memset through the emulator's HLE -- all verified
// correct. See docs/adr/0047-psp-memory-budget.md.
//
// Fix: take over the two entry points that matter and do the search here.
// frame_dummy hands the .eh_frame base to __register_frame_info as its first
// argument, so capturing it needs no linker-script symbol and no reach into
// libgcc's file-static registry; _Unwind_Find_FDE is then answered from an
// index this file builds and sorts itself. Both overrides win the link
// because this translation unit is listed in add_executable() ahead of every
// library, under the -Wl,--allow-multiple-definition the EBOOT already sets
// (see app/psp/CMakeLists.txt) -- first definition wins, and libgcc's copies
// are simply never reached.
//
// Deliberately narrow. It reads each CIE's augmentation to find the FDE
// pointer encoding, and requires every one of them to be a 4-byte absolute
// form (absptr/udata4/sdata4) -- which is what this toolchain emits, and what
// libgcc itself concluded, since it set mixed_encoding=0 on this object. This
// EBOOT carries three CIEs: one "zR" and two "zPLR", so stepping over a 'P'
// (personality routine: an encoding byte plus an encoded pointer) and an 'L'
// (LSDA encoding byte) is required, not optional. Anything it does not
// recognise disables the whole override, leaving libgcc's behaviour untouched
// rather than guessing. Drop the whole file once pspdev's libgcc sorts
// correctly; psp_unwind_fde_ok() is what tells you whether it engaged.

#include <stdlib.h>

namespace {

// libgcc's dwarf_eh_bases, which _Unwind_Find_FDE fills in for its caller.
struct DwarfEhBases {
  void* tbase;
  void* dbase;
  void* func;
};

const unsigned char* g_eh_frame = nullptr;
const unsigned char** g_fdes = nullptr;
unsigned g_count = 0;
bool g_built = false;
bool g_disabled = false;

unsigned read_u32(const unsigned char* p) {
  return static_cast<unsigned>(p[0]) | (static_cast<unsigned>(p[1]) << 8) |
         (static_cast<unsigned>(p[2]) << 16) |
         (static_cast<unsigned>(p[3]) << 24);
}

// The FDE's pc_begin, for the 4-byte absolute encodings this file accepts.
unsigned fde_pc_begin(const unsigned char* fde) {
  return read_u32(fde + 8);
}
unsigned fde_pc_range(const unsigned char* fde) {
  return read_u32(fde + 12);
}

const unsigned char* skip_uleb(const unsigned char* p) {
  while (*p & 0x80)
    ++p;
  return p + 1;
}

// Step over one encoded pointer of the given encoding, or null if it is a form
// this file does not decode (DW_EH_PE_aligned in particular, which would need
// the section's own alignment).
const unsigned char* skip_encoded(const unsigned char* p, unsigned char enc) {
  if (enc == 0xff)  // DW_EH_PE_omit
    return p;
  switch (enc & 0x07) {
    case 0x00:
      return p + 4;  // absptr, 32-bit target
    case 0x02:
      return p + 2;  // udata2
    case 0x03:
      return p + 4;  // udata4
    case 0x04:
      return p + 8;  // udata8
    case 0x01:       // uleb128
    case 0x05:
      return skip_uleb(p);
    default:
      return nullptr;
  }
}

// The FDE pointer encoding named by a CIE's 'R' augmentation character, or
// 0xff if this CIE is not a shape we handle. Requires a 'z' augmentation, so
// that the augmentation data is self-describing, then walks the remaining
// characters consuming what each one contributes.
unsigned char cie_fde_encoding(const unsigned char* cie) {
  const unsigned char* p = cie + 8;  // past length and the zero CIE id
  const unsigned char version = *p++;
  if (version != 1 && version != 3)
    return 0xff;
  const unsigned char* const aug = p;
  while (*p)
    ++p;
  ++p;  // past the augmentation string's NUL
  if (aug[0] != 'z')
    return 0xff;
  p = skip_uleb(p);  // code alignment factor
  p = skip_uleb(p);  // data alignment factor (SLEB, same continuation rule)
  p = (version == 1) ? p + 1 : skip_uleb(p);  // return address register
  p = skip_uleb(p);                           // augmentation data length
  for (const unsigned char* c = aug + 1; *c; ++c) {
    switch (*c) {
      case 'R':
        return *p;
      case 'L':
        ++p;
        break;
      case 'P': {
        const unsigned char enc = *p++;
        p = skip_encoded(p, enc);
        if (!p)
          return 0xff;
        break;
      }
      case 'S':  // signal frame: no augmentation data
        break;
      default:
        return 0xff;
    }
  }
  return 0xff;
}

bool encoding_is_absolute_4byte(unsigned char enc) {
  if ((enc & 0x70) != 0x00)  // anything but absptr application
    return false;
  const unsigned char format = enc & 0x0f;
  return format == 0x00 || format == 0x03 ||
         format == 0x0b;  // absptr/udata4/sdata4
}

void sift(const unsigned char** a, unsigned root, unsigned n) {
  for (;;) {
    unsigned child = root * 2u + 1u;
    if (child >= n)
      return;
    if (child + 1u < n && fde_pc_begin(a[child]) < fde_pc_begin(a[child + 1u]))
      ++child;
    if (fde_pc_begin(a[root]) >= fde_pc_begin(a[child]))
      return;
    const unsigned char* t = a[root];
    a[root] = a[child];
    a[child] = t;
    root = child;
  }
}

void sort_fdes(const unsigned char** a, unsigned n) {
  for (unsigned start = n / 2u; start-- > 0u;)
    sift(a, start, n);
  for (unsigned end = n; end > 1u;) {
    --end;
    const unsigned char* t = a[0];
    a[0] = a[end];
    a[end] = t;
    sift(a, 0u, end);
  }
}

// Walk the table once to count FDEs and vet every CIE, then again to fill the
// index. Two passes rather than a growing array: this runs once, on the first
// throw, and a fixed allocation keeps it out of the way of whatever the
// program was doing.
void build_index() {
  g_built = true;
  if (!g_eh_frame) {
    g_disabled = true;
    return;
  }
  for (int pass = 0; pass < 2; ++pass) {
    const unsigned char* p = g_eh_frame;
    unsigned n = 0;
    for (;;) {
      const unsigned length = read_u32(p);
      if (length == 0 || length == 0xffffffffu)  // terminator, or 64-bit DWARF
        break;
      const unsigned char* const next = p + 4 + length;
      if (read_u32(p + 4) == 0) {  // CIE
        if (pass == 0 && !encoding_is_absolute_4byte(cie_fde_encoding(p))) {
          g_disabled = true;
          return;
        }
      } else {
        if (pass == 1)
          g_fdes[n] = p;
        ++n;
      }
      p = next;
    }
    if (pass == 0) {
      if (n == 0) {
        g_disabled = true;
        return;
      }
      g_fdes = static_cast<const unsigned char**>(malloc(n * sizeof(*g_fdes)));
      if (!g_fdes) {
        g_disabled = true;
        return;
      }
      g_count = n;
    }
  }
  sort_fdes(g_fdes, g_count);
}

}  // namespace

extern "C" {

// frame_dummy's call. The `object` libgcc wants to thread onto its own list is
// unused here: nothing in this file consults libgcc's registry, and the
// matching __deregister_frame_info below keeps its bookkeeping consistent.
void __register_frame_info(const void* begin, void* /*object*/) {
  g_eh_frame = static_cast<const unsigned char*>(begin);
}

// __do_global_dtors_aux's counterpart. libgcc's own version walks its registry
// and asserts when the object is missing -- which it always would be here --
// so this has to be overridden too, or shutdown aborts. The result is
// discarded by every caller in crtstuff.
void* __deregister_frame_info(const void* /*begin*/) {
  return nullptr;
}

const void* _Unwind_Find_FDE(void* pc, DwarfEhBases* bases) {
  if (!g_built)
    build_index();
  if (g_disabled)
    return nullptr;

  const unsigned target = reinterpret_cast<unsigned>(pc);
  unsigned lo = 0, hi = g_count;
  while (lo < hi) {
    const unsigned mid = lo + (hi - lo) / 2u;
    const unsigned begin = fde_pc_begin(g_fdes[mid]);
    if (target < begin) {
      hi = mid;
    } else if (target >= begin + fde_pc_range(g_fdes[mid])) {
      lo = mid + 1u;
    } else {
      bases->tbase = nullptr;
      bases->dbase = nullptr;
      bases->func = reinterpret_cast<void*>(begin);
      return g_fdes[mid];
    }
  }
  return nullptr;
}

// Non-zero when the index built cleanly, for a caller that wants to report it.
int psp_unwind_fde_ok(void) {
  if (!g_built)
    build_index();
  return (!g_disabled && g_count != 0) ? static_cast<int>(g_count) : 0;
}

}  // extern "C"
