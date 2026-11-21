- **bc2cpp**: a receiver the flow proves an Integer is now an exact-Integer
  site, so `n.times { }` / `n.downto(m) { }` call the compiled Integer body
  with no class test and `to_s` / `to_i` take the audited direct path; 14
  fewer owner calls in the closed build (1334 to 1320).
