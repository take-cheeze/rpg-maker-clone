# mruby-regexp-alias: the Regexp constant for code that names it, backed by mruby-onig-regexp.
#
# mruby has no core Regexp class. mruby-onig-regexp provides OnigRegexp, which is the regexp class this build uses, and
# the Ruby libraries the generators load (RBS, Prism's tooling) name Regexp directly. This gem makes Regexp the same
# class as OnigRegexp, when no other gem has defined it.
MRuby::Gem::Specification.new('mruby-regexp-alias') do |spec|
  spec.license = 'MIT'
  spec.authors = 'take-cheeze'
  spec.summary = 'Regexp, as an alias of OnigRegexp, for mruby'
  spec.add_dependency 'mruby-onig-regexp'
end
