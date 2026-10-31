- The bc2cpp class-body driver (`tools/bc2cpp/codegen_class_body.rb`) now
  compiles a zero-argument send (`SEND0`), the last opcode it refused. The one
  body it refused was core `Enumerable`, whose `NONE = Object.new` compiles to
  `GETCONST Object` then `SEND0 :new`; the unit emits the same plain
  `mrb_funcall(M, r, "new", 0)` a `SEND` site already emits.
  `scripts/bc2cpp/class_body_compile_list.rb` now reports all **254** class and
  module bodies, `scripts/bc2cpp/class_body_left_ops_check.rb`'s `KNOWN_LEFT`
  list is empty (it fails if `SEND0` refuses a body again), and
  `scripts/bc2cpp/class_body_unit_check.rb` holds the shape. The emitted units
  of the closed build are unchanged; one spare const-site cache slot
  (`bc2cpp_cconst_slots` 668 -> 669) is spent on a body the unit selector then
  leaves out.
