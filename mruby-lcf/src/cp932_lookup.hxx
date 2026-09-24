#pragma once

// Lookups over the tables cp932_to_unicode.rb generates (ADR 0217).
// scripts/cp932_tables_check.rb compares both against ADR 0111's pair tables
// for every 16-bit input.

#include "cp932.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>

// CP932 code (a single byte, or lead << 8 | trail) -> Unicode code point.
inline std::optional<uint16_t> cp932_decode(const uint16_t code) {
  if (code <= 0xff) {
    const uint16_t u = cp932_single[code];
    return u == CP932_UNMAPPED ? std::nullopt : std::optional<uint16_t>(u);
  }
  const unsigned lead = code >> 8, trail = code & 0xff;
  if (lead >= CP932_EUDC_LEAD_FIRST and lead <= CP932_EUDC_LEAD_LAST) {
    if (trail < CP932_TRAIL_FIRST or trail > CP932_TRAIL_LAST or
        trail == CP932_TRAIL_GAP)
      return std::nullopt;
    return static_cast<uint16_t>(
        CP932_EUDC_UNICODE_FIRST +
        (lead - CP932_EUDC_LEAD_FIRST) * CP932_EUDC_ROW + trail -
        (trail < CP932_TRAIL_GAP ? CP932_TRAIL_FIRST : CP932_TRAIL_FIRST + 1));
  }
  if (lead < CP932_LEAD_FIRST or lead > CP932_LEAD_LAST)
    return std::nullopt;
  const Cp932Row& row = cp932_rows[lead - CP932_LEAD_FIRST];
  if (trail < row.first_trail or trail > row.last_trail)
    return std::nullopt;
  const uint16_t u = cp932_double[row.offset + trail - row.first_trail];
  return u == CP932_UNMAPPED ? std::nullopt : std::optional<uint16_t>(u);
}

// Unicode code point -> CP932 code; a result <= 0xff is a single byte.
inline std::optional<uint16_t> cp932_encode(const uint16_t u) {
  using Pair = std::pair<uint16_t, uint16_t>;
  const auto by_unicode = [](const Pair& l, const uint16_t r) {
    return l.first < r;
  };
#ifndef CP932_NO_REVERSE_TABLE
  const Pair* const e = cp932_reverse_table + cp932_reverse_table_len;
  const Pair* const i = std::lower_bound(cp932_reverse_table, e, u, by_unicode);
  return i < e and i->first == u ? std::optional<uint16_t>(i->second)
                                 : std::nullopt;
#else
  // WCTABLE maps each code point once (cp932_to_unicode.rb checks), so the
  // first hit in any of the tables below is the only one.
  if (u == CP932_UNMAPPED)
    return std::nullopt;
  const Pair* const xe = cp932_encode_extra + cp932_encode_extra_len;
  const Pair* const x = std::lower_bound(cp932_encode_extra, xe, u, by_unicode);
  if (x < xe and x->first == u)
    return x->second;
  const unsigned pua = u - CP932_EUDC_UNICODE_FIRST;
  if (u >= CP932_EUDC_UNICODE_FIRST and
      pua <
          (CP932_EUDC_LEAD_LAST - CP932_EUDC_LEAD_FIRST + 1) * CP932_EUDC_ROW) {
    const unsigned t = pua % CP932_EUDC_ROW + CP932_TRAIL_FIRST;
    return static_cast<uint16_t>((CP932_EUDC_LEAD_FIRST + pua / CP932_EUDC_ROW)
                                     << 8 |
                                 (t < CP932_TRAIL_GAP ? t : t + 1));
  }
  for (unsigned c = 0; c < 0x100; ++c)
    if (cp932_single[c] == u)
      return static_cast<uint16_t>(c);
  const uint16_t* const d =
      std::find(cp932_double, cp932_double + cp932_double_len, u);
  if (d == cp932_double + cp932_double_len)
    return std::nullopt;
  const size_t off = d - cp932_double;
  for (unsigned lead = CP932_LEAD_FIRST; lead <= CP932_LEAD_LAST; ++lead) {
    const Cp932Row& row = cp932_rows[lead - CP932_LEAD_FIRST];
    if (row.first_trail <= row.last_trail and off >= row.offset and
        off <= row.offset + (row.last_trail - row.first_trail))
      return static_cast<uint16_t>(lead << 8 |
                                   (row.first_trail + (off - row.offset)));
  }
  return std::nullopt;  // unreachable: every cp932_double slot is in a row
#endif
}
