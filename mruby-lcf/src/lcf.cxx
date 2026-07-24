#include <mruby.h>
#include "cp932.h"

#include <algorithm>
#include <optional>

#include <uni_algo/conv.h>

namespace {

mrb_value cp932_to_utf8(mrb_state* M, mrb_value self) {
  const uint8_t* p;
  mrb_int l;
  mrb_get_args(M, "s", &p, &l);

  const auto find_utf8 = [](const uint16_t v) -> std::optional<uint16_t> {
    const auto cmp = [](const std::pair<uint16_t, uint16_t>& l,
                        const uint16_t& r) -> bool { return l.first < r; };
    const auto* e = cp932_table + cp932_table_len;
    const auto* i = std::lower_bound(cp932_table, e, v, cmp);
    if (i < e and i->first == v)
      return i->second;
    else
      return std::nullopt;
  };

  std::u32string str;
  for (const uint8_t* i = p; i < p + l; ++i) {
    const uint8_t b[2] = {i[0],
                          static_cast<uint8_t>((p + l - i) >= 2 ? i[1] : 0x00)};
    std::optional<uint16_t> u = find_utf8(b[0] << 8 | b[1]);
    if (u) {
      str.push_back(*u);
      i += 1;
      continue;
    }
    // ASCII characters
    if (b[0] < 0x80) {
      str.push_back(b[0]);
      continue;
    }
    u = find_utf8(b[0]);
    if (u) {
      str.push_back(*u);
      continue;
    }
    // Unmappable byte: the best-fit table (used here in reverse as a decoder)
    // does not cover every valid CP932 code, and the input may contain
    // truncated multi-byte sequences or invalid bytes. Emit U+FFFD instead of
    // aborting the whole process. When the byte is a double-byte lead byte and
    // a trailing byte follows, consume both so the stream stays in sync.
    str.push_back(0xFFFD);
    const bool is_dbcs_lead =
        (b[0] >= 0x81 and b[0] <= 0x9F) or (b[0] >= 0xE0 and b[0] <= 0xFC);
    if (is_dbcs_lead and (p + l - i) >= 2)
      i += 1;
  }
  std::string ret = una::utf32to8(str);

  return mrb_str_new(M, ret.data(), ret.size());
}

}  // namespace

extern "C" void mrb_mruby_lcf_gem_init(mrb_state* M) {
  RClass* mod = mrb_define_module(M, "LCF");
  mrb_define_module_function(M, mod, "cp932_to_utf8", cp932_to_utf8,
                             MRB_ARGS_REQ(1));
}

extern "C" void mrb_mruby_lcf_gem_final(mrb_state* M) {}
