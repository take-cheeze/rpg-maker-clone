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
    fprintf(stderr, "%x\n", int(v));
    const auto cmp = [](const std::pair<uint16_t, uint16_t>& l,
                        const uint16_t& r) -> bool { return l.first < r; };
    const auto* e = cp932_table + cp932_table_len;
    const auto* i = std::lower_bound(cp932_table, e, v, cmp);
    fprintf(stderr, "%x\n", int(i->first));
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
    u = find_utf8(b[0]);
    mrb_assert(u);
    str.push_back(*u);
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
