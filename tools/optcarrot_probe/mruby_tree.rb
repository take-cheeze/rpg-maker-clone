# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'find'

# The mruby tree (3rd/mruby) the optcarrot probe builds against, and the patches it needs. Shared by
# compiled_run.rb and build_bundle.rb.
#
# A serial run applies the patches to the tree in place, as it always has. A run with OPTCARROT_WORK_DIR set
# can run beside others (docs/ci.md, "Parallel groups"), so it never writes the tree: the patches must already be
# applied, and the run builds in a copy made here, which is checked against the tree by digest.
module OptcarrotMRubyTree
  ROOT = File.expand_path('../..', __dir__)
  APPLY_SCRIPT = File.join(ROOT, 'scripts/apply_mruby_patch.bash')
  # In the order the probe has always applied them. cmake/build-mruby.cmake applies every one of these too.
  PATCHES = %w[
    mruby-colon3-assign-setmcnst.patch
    mruby-dollar-bang-scoped.patch
    mruby-defined-keyword.patch
    mruby-module-function-scope.patch
    mruby-parser-dump-back-nth-ref.patch
    mruby-nomemoryerror-reentrant-alloc.patch
    mruby-gc-type-live-counts.patch
    mruby-rdata-ivar-slots.patch
  ].map { |name| File.join(ROOT, 'patches', name) }.freeze

  module_function

  # Idempotent (apply_mruby_patch.bash does nothing for a patch that is already in).
  def apply_patch(mruby, patch)
    system(APPLY_SCRIPT, mruby, patch, exception: true)
  end

  # Reads only: exit 0 from a reverse dry run means the patch is already applied. -N and -t are not used,
  # because -t reports a patch that is not applied as applied.
  def patch_applied?(mruby, patch)
    system('patch', '-p1', '-R', '-N', '--dry-run', '-s', '-i', patch,
           chdir: mruby, in: File::NULL, out: File::NULL, err: File::NULL)
  end

  def check_patches!(mruby, patches = PATCHES)
    missing = patches.reject { |patch| patch_applied?(mruby, patch) }
    return if missing.empty?

    raise "#{mruby} lacks #{missing.map { |patch| File.basename(patch) }.join(', ')}; apply the probe's " \
          'patches first (cmake --build build-bc2cpp --target mruby_host_mrbc, or one serial compiled_run.rb run)'
  end

  # Every file, link and directory under dir with its mode and contents, skipping the top-level build/ (the
  # build's output, not the source). Find yields entries sorted, so the digest is deterministic.
  def tree_digest(dir)
    digest = Digest::SHA256.new
    Find.find(dir) do |path|
      next if path == dir

      relative = path.delete_prefix("#{dir}/")
      Find.prune if relative == 'build'
      stat = File.lstat(path)
      digest << "#{relative}\0#{stat.ftype}\0#{stat.mode & 0o7777}\0"
      if stat.symlink?
        digest << File.readlink(path)
      elsif stat.file?
        digest << Digest::SHA256.file(path).hexdigest
      end
      digest << "\0"
    end
    digest.hexdigest
  end

  # A fresh copy of mruby's tree without build/, under dest. Raises unless the copy's digest equals the source's,
  # so a run builds from exactly the tree whose patches were checked.
  def copy_tree(mruby, dest)
    FileUtils.rm_rf(dest)
    FileUtils.mkdir_p(dest)
    entries = Dir.children(mruby).reject { |name| name == 'build' }.map { |name| File.join(mruby, name) }
    system('cp', '-a', *entries, dest, exception: true)
    source = tree_digest(mruby)
    copy = tree_digest(dest)
    raise "copy #{dest} differs from #{mruby} (#{copy} != #{source})" unless copy == source

    dest
  end
end
