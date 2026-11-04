# mruby-require: Kernel#require for this project's mruby builds, with no file loading.
#
# A feature is what a gem or mrblib provides, named as the script it came from ('rbs/buffer') or as the
# library name ('set'). Each feature registers a check that the code is really present; require returns
# true the first time (after the check passes), false afterwards, and raises LoadError for anything no
# gem provides, so a missing library fails with its name instead of an undefined method.
MRuby::Gem::Specification.new('mruby-require') do |spec|
  spec.license = 'MIT'
  spec.authors = 'take-cheeze'
  spec.summary = 'Kernel#require over the features the mrbgems and mrblibs of this build provide'
end
