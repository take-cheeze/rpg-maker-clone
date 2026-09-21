- bc2cpp now substitutes the call-site argument when generating supported
  one-argument native methods from mruby C sources. Hash#key?, #has_key?, and
  #member? use mruby's public hash lookup helper behind an exact Hash guard.
