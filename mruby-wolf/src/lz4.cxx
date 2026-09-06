// Native LZ4 block decoder for Wolf::LZ4.decompress (mruby-wolf/mrblib/wolf.rb
// no longer defines a Ruby-level fallback -- mruby-lcf's LCF.cp932_to_utf8
// follows the same shape, native-only in the real build, with a CRuby stand-in
// in scripts/wolf_testbed_check.rb for the host check).
//
// A 3.5+ WOLF RPG Editor file (CommonEvent.dat, *DataBase.dat, .mps) wraps its
// body in one LZ4 *block* (no frame header) after its plain header. A hand-
// written interpreted decoder -- building the output by repeatedly appending
// small mruby Strings, one per literal run and match -- measured **3.3
// seconds** decompressing the editor's own bundled CommonEvent.dat (1.3 MB
// from 106,477 tokens averaging 11 bytes each: WOLF RPG Editor's bytecode-like
// event data compresses to many *short* matches, not few long ones), and an
// earlier byte-at-a-time version of the same overlapping-match copy exhausted
// LVGL's 512 MiB heap outright (`NoMemoryError`) on the same file before a
// single-pass native loop replaced it. See
// docs/adr/0064-wolf-rpg-editor-data-layer.md.
#include <mruby.h>
#include <mruby/string.h>

#include <cstdint>
#include <string>

namespace {

constexpr uint32_t kMinMatch = 4;

[[noreturn]] void raise_lz4_error(mrb_state* M, const char* msg) {
  RClass* wolf = mrb_module_get(M, "Wolf");
  RClass* err = mrb_class_get_under(M, wolf, "Error");
  mrb_raise(M, err, msg);
}

mrb_value lz4_decompress(mrb_state* M, mrb_value) {
  const uint8_t* src;
  mrb_int src_len;
  mrb_int dst_size;
  mrb_get_args(M, "si", &src, &src_len, &dst_size);

  if (dst_size < 0)
    raise_lz4_error(M, "LZ4: negative destination size");

  std::string out;
  out.reserve(static_cast<size_t>(dst_size));

  const size_t n = static_cast<size_t>(src_len);
  size_t i = 0;
  while (i < n) {
    const uint8_t token = src[i++];
    uint32_t lit = token >> 4;
    if (lit == 15) {
      for (;;) {
        if (i >= n)
          raise_lz4_error(M, "LZ4: truncated literal length");
        const uint8_t b = src[i++];
        lit += b;
        if (b != 255)
          break;
      }
    }
    if (lit > 0) {
      if (i + lit > n)
        raise_lz4_error(M, "LZ4: truncated literals");
      out.append(reinterpret_cast<const char*>(src + i), lit);
      i += lit;
    }
    // The last sequence in a block carries literals only.
    if (i >= n)
      break;

    if (i + 2 > n)
      raise_lz4_error(M, "LZ4: truncated match offset");
    const uint32_t offset = static_cast<uint32_t>(src[i]) |
                            (static_cast<uint32_t>(src[i + 1]) << 8);
    i += 2;
    if (offset == 0)
      raise_lz4_error(M, "LZ4: zero match offset");
    if (offset > out.size())
      raise_lz4_error(M, "LZ4: match offset before start of output");

    uint32_t mlen = token & 0xf;
    if (mlen == 15) {
      for (;;) {
        if (i >= n)
          raise_lz4_error(M, "LZ4: truncated match length");
        const uint8_t b = src[i++];
        mlen += b;
        if (b != 255)
          break;
      }
    }
    mlen += kMinMatch;

    const size_t start = out.size() - offset;
    if (offset >= mlen) {
      // Source and destination ranges cannot overlap: append is safe as-is.
      out.append(out.data() + start, mlen);
    } else {
      // An overlapping match: the `offset`-byte unit at `start` repeats
      // periodically for `mlen` bytes. Grow the buffer once, then copy
      // byte-by-byte through the same buffer -- `data[start + k]` is always
      // an index strictly below the one it writes (`old_size + k`), since
      // `offset >= 1`, so every source byte was already written by the time
      // it is read, exactly reproducing the repeating pattern with no
      // temporary allocations regardless of how long the run is.
      const size_t old_size = out.size();
      out.resize(old_size + mlen);
      char* data = &out[0];
      for (uint32_t k = 0; k < mlen; ++k)
        data[old_size + k] = data[start + k];
    }
  }

  if (out.size() != static_cast<size_t>(dst_size)) {
    raise_lz4_error(M,
                    "LZ4: decoded size does not match the declared "
                    "destination size");
  }

  return mrb_str_new(M, out.data(), out.size());
}

}  // namespace

extern "C" void mrb_mruby_wolf_gem_init(mrb_state* M) {
  RClass* wolf = mrb_define_module(M, "Wolf");
  RClass* lz4 = mrb_define_module_under(M, wolf, "LZ4");
  mrb_define_module_function(M, lz4, "decompress", lz4_decompress,
                             MRB_ARGS_REQ(2));
}

extern "C" void mrb_mruby_wolf_gem_final(mrb_state*) {}
