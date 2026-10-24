- **bc2cpp**: a read of a proven record key (`@ui[:sprites]`) now enters the
  exact-class flow as its stored Array/Hash/String classes plus nil when the
  key can be absent, so the flow's truthiness narrowing makes
  `(@ui[:k] || []).each`, `return unless x` and the like exact receivers, and a
  plain read a NILABLE_RECEIVER. On the closed world, against
  `BC2CPP_RECORD_NILABLE_READS=0` on the same tree, this removes 2
  `bc2cpp_send` and 6 `mrb_funcall_with_block` by-name sites and 5
  `bc2cpp_nomethod` sites, adds 45 NILABLE_RECEIVER nil arms, and shrinks the
  generated C++ by 464 lines, all in `RPG2k::Scene::Battle`/`Base`. Checked by
  `scripts/bc2cpp/record_nilable_read_check.rb`.
