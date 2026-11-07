#!/usr/bin/env ruby
# frozen_string_literal: true

# RESPOND_TO_FOLD: `x.respond_to?(:name)` on a receiver whose class the proof makes exact folds to the closed
# world's answer. A defined name folds to true (mruby's respond_to? ignores visibility, so a private method
# answers true too), and a name no definition or native answers folds to false. The interpreted and compiled
# runs must print the same lines.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/respond_to_fold_check.rb
require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = FixtureCheck.new('respond_to_fold_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Thing
    def kind_name; 1; end
    private def secret; 2; end
  end

  class User
    def go
      t = Thing.new
      [t.respond_to?(:kind_name), t.respond_to?(:secret), t.respond_to?(:nope)]
    end
  end
RUBY

DRIVER = <<~RUBY
  p User.new.go
  puts 'end'
RUBY

OWNERS = %w[Thing User].freeze

build = Bc2cppFixtureRuntime.full_or_build
check.call('a full-core libmruby builds for the parity runs', !build.nil?)
if build
  Dir.mktmpdir('respond_to_fold') do |dir|
    sig = File.join(dir, 'sig')
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, 'empty.rbs'), "# fixture: no declarations\n")
    ENV['BC2CPP_SIG_DIRS'] = sig
    _code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: OWNERS)
    emitted = Dir.glob(File.join(dir, '**', '*.{cpp,cxx,c}')).map { |f| File.read(f) }.join("\n")
    folds = emitted.scan(/RESPOND_TO_FOLD :respond_to\?/).size
    check.call('the constant names fold: all three calls (kind_name, secret, nope) fold to the closed world answer', folds == 3)
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"APD(#{DRIVER})APD";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: build, full: true)
    sections = built ? Bc2cppFixtureRuntime.sections(output) : {}
    check.call('the driver runs to its end (interpreted)', sections['interpreted']&.last == 'end')
    ENV.delete('BC2CPP_SIG_DIRS')
    check.call('interpreted and compiled runs print the same',
               sections['interpreted'] && sections['interpreted'] == sections['compiled'])
  end
end

suite.finish!
