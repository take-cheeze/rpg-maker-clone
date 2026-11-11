# frozen_string_literal: true

# Copies the gem trees under compiled-gem-templates/ to the repository root (mruby-*-compiled/,
# mruby-fiber-placeholder/), where build_config.rb's conf.gem paths, the bc2cpp closure and the checks read them.
# The root copies are generated and gitignored; only the templates are tracked. Each file is rewritten only when its
# content differs, so an up-to-date copy keeps its mtime and does not dirty the build.
require 'fileutils'

module CompiledGemTemplates
  DIR = __dir__
  ROOT = File.expand_path('..', DIR)

  module_function

  # Returns the staged directory of each template tree, keyed by gem name.
  def stage!(root = ROOT)
    Dir.children(DIR).sort.each_with_object({}) do |name, staged|
      source = File.join(DIR, name)
      next unless File.directory?(source)

      target = File.join(root, name)
      Dir.glob('**/*', base: source).sort.each do |rel|
        from = File.join(source, rel)
        next unless File.file?(from)

        to = File.join(target, rel)
        FileUtils.mkdir_p(File.dirname(to))
        FileUtils.cp(from, to) unless File.file?(to) && File.binread(to) == File.binread(from)
      end
      staged[name] = target
    end
  end
end

# `ruby compiled-gem-templates/stage.rb`: what cmake/build-mruby.cmake runs at configure time, before it globs the gems' src/.
CompiledGemTemplates.stage! if $PROGRAM_NAME == __FILE__
