- **bc2cpp ivar class facts**: a census of why ivars lose their class (`== ivar-class OPAQUE causes ==` in the
  diagnostic, `BC2CPP_POOL_DROP_REPORT=1` for the dropped class pools; 175 of the 598 OPAQUE ivars hold only
  immediates and can never have a class hint), and two sound rules for the class pools: constructors with keyword
  parameters and keyword `new` / `super` calls join the argument pools (`BC2CPP_CTOR_KEYWORDS=0` turns it off), and
  `self` in a uniquely owned instance method is its class set (`BC2CPP_POOL_SELF_CLASS=0`). Six more constructors are
  pooled, 17 compiled functions lose a class test or a `bc2cpp_nomethod` arm. ADR 0382; checks
  `scripts/bc2cpp_ivar_typing_check.rb` and `scripts/bc2cpp_ivar_typing_mutation_check.rb`.
