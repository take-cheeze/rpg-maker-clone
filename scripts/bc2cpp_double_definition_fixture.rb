# frozen_string_literal: true

# Ruby fixtures shared by scripts/bc2cpp_double_definition_check.rb and its mutation check (ADR 0319).
#
# Every class is named after a wired embedding owner (tools/bc2cpp/compiled_gems.rb BC2CPP_WIRED_EMBEDDINGS)
# because only those get a generated registration; a fixture class of any other name would never run its
# compiled body. The classes are the fixture's own: the harness has no engine gem. Each form gets its own
# owner, so a form can be compiled alone (FORMS) or all together (PROGRAM and DRIVER).
module DoubleDefinitionFixture
  # +names+ are renamed per form (v -> v_attr_then_def) so that no two forms share a method name: a shared
  # name is POLY and would hide the devirtualized call this fixture exists to exercise.
  Form = Struct.new(:name, :owners, :names, :program, :driver, :late, keyword_init: true) do
    def rename(text)
      names.reduce(text) { |out, n| out.gsub(/(?<!\w)#{Regexp.escape(n)}(?!\w)/) { "#{n}_#{self.name}" } }
    end
  end

  FORMS = [
    # attr_reader, then a def of the same name
    Form.new(name: 'attr_then_def', names: %w[v], owners: %w[Game::Screen], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class Screen
          attr_reader :v
          def v; 10; end
          def initialize; @v = 1; end
          def run_v; v; end
          def via(o); o.v; end
        end
      end
    RUBY
      dd_show('attr_then_def self') { Game::Screen.new.run_v }
      dd_show('attr_then_def explicit') { s = Game::Screen.new; s.via(s) }
    RUBY
    # def, then attr_reader
    Form.new(name: 'def_then_attr', names: %w[v], owners: %w[Game::ChipSet], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class ChipSet
          def v; 10; end
          attr_reader :v
          def initialize; @v = 7; end
          def run_v; v; end
          def via(o); o.v; end
        end
      end
    RUBY
      dd_show('def_then_attr self') { Game::ChipSet.new.run_v }
      dd_show('def_then_attr explicit') { s = Game::ChipSet.new; s.via(s) }
    RUBY
    # attr_accessor, then a def of the writer
    Form.new(name: 'accessor_then_def_writer', names: %w[w], owners: %w[Game::Switches], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class Switches
          attr_accessor :w
          def w=(x); @w = x * 2; end
          def initialize; @w = 0; end
          def put(x); self.w = x; w; end
          def via(o, x); o.w = x; o.w; end
        end
      end
    RUBY
      dd_show('accessor_then_def_writer self') { Game::Switches.new.put(3) }
      dd_show('accessor_then_def_writer explicit') { s = Game::Switches.new; s.via(s, 4) }
    RUBY
    # attr_reader, then define_method
    Form.new(name: 'attr_then_define_method', names: %w[v], owners: %w[Game::Map], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class Map
          attr_reader :v
          define_method(:v) { 42 }
          def initialize; @v = 1; end
          def run_v; v; end
          def via(o); o.v; end
        end
      end
    RUBY
      dd_show('attr_then_define_method self') { Game::Map.new.run_v }
      dd_show('attr_then_define_method explicit') { s = Game::Map.new; s.via(s) }
    RUBY
    # define_method, then attr_reader
    Form.new(name: 'define_method_then_attr', names: %w[v], owners: %w[Game::State], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class State
          define_method(:v) { 42 }
          attr_reader :v
          def initialize; @v = 5; end
          def run_v; v; end
          def via(o); o.v; end
        end
      end
    RUBY
      dd_show('define_method_then_attr self') { Game::State.new.run_v }
      dd_show('define_method_then_attr explicit') { s = Game::State.new; s.via(s) }
    RUBY
    # def, then define_method
    Form.new(name: 'def_then_define_method', names: %w[v], owners: %w[Game::Timer], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class Timer
          def v; 1; end
          define_method(:v) { 2 }
          def initialize; @t = 0; end
          def run_v; v; end
          def via(o); o.v; end
        end
      end
    RUBY
      dd_show('def_then_define_method self') { Game::Timer.new.run_v }
      dd_show('def_then_define_method explicit') { s = Game::Timer.new; s.via(s) }
    RUBY
    # define_method, then def
    Form.new(name: 'define_method_then_def', names: %w[v], owners: %w[Game::Shop], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class Shop
          define_method(:v) { 2 }
          def v; 1; end
          def initialize; @t = 0; end
          def run_v; v; end
          def via(o); o.v; end
        end
      end
    RUBY
      dd_show('define_method_then_def self') { Game::Shop.new.run_v }
      dd_show('define_method_then_def explicit') { s = Game::Shop.new; s.via(s) }
    RUBY
    # def, then def
    Form.new(name: 'def_then_def', names: %w[v], owners: %w[Game::Troop], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class Troop
          def v; 1; end
          def v; 2; end
          def initialize; @t = 0; end
          def run_v; v; end
          def via(o); o.v; end
          def twice; v + v; end
        end
      end
    RUBY
      dd_show('def_then_def self') { Game::Troop.new.run_v }
      dd_show('def_then_def explicit') { s = Game::Troop.new; s.via(s) }
      dd_show('def_then_def twice') { Game::Troop.new.twice }
    RUBY
    # three definitions, the last one raises
    Form.new(name: 'triple_def_raises', names: %w[v], owners: %w[Game::EnemyAi], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class EnemyAi
          def v; 1; end
          def v; 2; end
          def v; raise ArgumentError, 'third'; end
          def initialize; @t = 0; end
          def run_v; v; end
          def via(o); o.v; end
        end
      end
    RUBY
      dd_show('triple_def_raises self') { Game::EnemyAi.new.run_v }
      dd_show('triple_def_raises explicit') { s = Game::EnemyAi.new; s.via(s) }
    RUBY
    # a reopened class: the second body sits at the end of the program
    Form.new(name: 'reopened_class', names: %w[v], owners: %w[Game::Enemy], program: <<~'RUBY', driver: <<~'RUBY', late: <<~'RUBY'),
      module Game
        class Enemy
          def v; 1; end
          def initialize; @t = 0; end
          def run_v; v; end
          def via(o); o.v; end
        end
      end
    RUBY
      dd_show('reopened_class self') { Game::Enemy.new.run_v }
      dd_show('reopened_class explicit') { s = Game::Enemy.new; s.via(s) }
    RUBY
      module Game
        class Enemy
          def v; 2; end
        end
      end
    RUBY
    # alias / alias_method over an existing def
    Form.new(name: 'alias_over_def', names: %w[a b c], owners: %w[Game::Party], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class Party
          def a; 1; end
          def b; 2; end
          alias b a
          def c; 3; end
          alias_method :c, :a
          def initialize; @t = 0; end
          def run_b; b; end
          def run_c; c; end
          def via_b(o); o.b; end
          def via_c(o); o.c; end
        end
      end
    RUBY
      dd_show('alias_over_def alias self') { Game::Party.new.run_b }
      dd_show('alias_over_def alias explicit') { s = Game::Party.new; s.via_b(s) }
      dd_show('alias_over_def alias_method self') { Game::Party.new.run_c }
      dd_show('alias_over_def alias_method explicit') { s = Game::Party.new; s.via_c(s) }
    RUBY
    # alias, then the original redefined: the alias keeps the earlier body
    Form.new(name: 'alias_then_redefine', names: %w[a old], owners: %w[Game::Actors], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class Actors
          def a; 1; end
          alias old a
          def a; 2; end
          def initialize; @t = 0; end
          def run_a; a; end
          def run_old; old; end
          def via_a(o); o.a; end
        end
      end
    RUBY
      dd_show('alias_then_redefine original') { Game::Actors.new.run_a }
      dd_show('alias_then_redefine alias') { Game::Actors.new.run_old }
      dd_show('alias_then_redefine explicit') { s = Game::Actors.new; s.via_a(s) }
    RUBY
    # a later def that is conditional (not taken), and one that is taken
    Form.new(name: 'conditional_def', names: %w[v w], owners: %w[Game::Actor], program: <<~'RUBY', driver: <<~'RUBY'),
      $dd_flag_off = false
      $dd_flag_on = true
      module Game
        class Actor
          def v; 1; end
          def v; 2; end if $dd_flag_off
          def w; 1; end
          def w; 2; end if $dd_flag_on
          def initialize; @t = 0; end
          def run_v; v; end
          def run_w; w; end
          def via(o); [o.v, o.w]; end
        end
      end
    RUBY
      dd_show('conditional_def not taken') { Game::Actor.new.run_v }
      dd_show('conditional_def taken') { Game::Actor.new.run_w }
      dd_show('conditional_def explicit') { s = Game::Actor.new; s.via(s).join(',') }
    RUBY
    # a call that runs between the two definitions
    Form.new(name: 'call_between', names: %w[v], owners: %w[Game::Interpreter], program: <<~'RUBY', driver: <<~'RUBY'),
      $dd_seen = []
      module Game
        class Interpreter
          def v; 1; end
          $dd_seen << new.v
          def v; 2; end
          $dd_seen << new.v
          def initialize; @t = 0; end
          def run_v; v; end
          def via(o); o.v; end
        end
      end
    RUBY
      dd_show('call_between seen at load') { $dd_seen.join(',') }
      dd_show('call_between self') { Game::Interpreter.new.run_v }
      dd_show('call_between explicit') { s = Game::Interpreter.new; s.via(s) }
    RUBY
    # a live definition that raises where the dead one does not (core-only: String#succ is absent)
    Form.new(name: 'live_def_raises', names: %w[v], owners: %w[Game::Transition], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class Transition
          def v; 1; end
          def v; "ab".succ; end
          def initialize; @t = 0; end
          def run_v; v; end
          def via(o); o.v; end
        end
      end
    RUBY
      dd_show('live_def_raises self') { Game::Transition.new.run_v }
      dd_show('live_def_raises explicit') { s = Game::Transition.new; s.via(s) }
    RUBY
    # visibility: private after two definitions, and a redefinition after private
    Form.new(name: 'private_visibility', names: %w[v w], owners: %w[Game::TextReveal], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class TextReveal
          def v; 1; end
          def v; 2; end
          private :v
          def w; 1; end
          private :w
          def w; 2; end
          def initialize; @t = 0; end
          def run_v; v; end
          def run_w; w; end
        end
      end
    RUBY
      dd_show('private_visibility private self') { Game::TextReveal.new.run_v }
      dd_show('private_visibility private from outside') { Game::TextReveal.new.v }
      dd_show('private_visibility redefined self') { Game::TextReveal.new.run_w }
      dd_show('private_visibility redefined from outside') { Game::TextReveal.new.w }
    RUBY
    # super into a doubly defined parent method
    Form.new(name: 'super_into_double', names: %w[v], owners: %w[Game::NumberInput Game::MessageConfig], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class NumberInput
          def v; 1; end
          def v; 2; end
          def initialize; @t = 0; end
          def run_v; v; end
        end
        class MessageConfig < NumberInput
          def v; super + 100; end
          def run_s; v; end
        end
      end
    RUBY
      dd_show('super_into_double parent') { Game::NumberInput.new.run_v }
      dd_show('super_into_double child') { Game::MessageConfig.new.run_s }
    RUBY
    # the instance method `singleton_make` and `def self.make` share one C++ spelling
    Form.new(name: 'singleton_vs_instance_symbol', names: %w[], owners: %w[Game::Battle Game::Battle.singleton], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class Battle
          def singleton_make; 2; end
          def self.make; 1; end
          def self.pair(o); [make, o.singleton_make]; end
          def initialize; @t = 0; end
          def run_make; self.class.make; end
          def run_inst; singleton_make; end
        end
      end
    RUBY
      dd_show('singleton_vs_instance_symbol pair') { Game::Battle.pair(Game::Battle.new).join(',') }
      dd_show('singleton_vs_instance_symbol class') { Game::Battle.new.run_make }
      dd_show('singleton_vs_instance_symbol instance') { Game::Battle.new.run_inst }
    RUBY
    # `def self.m` twice, run from the same singleton
    Form.new(name: 'sdef_then_sdef', names: %w[m], owners: %w[Game::Party.singleton], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class Party
          def self.m; 1; end
          def self.m; 2; end
          def self.run_m; m; end
        end
      end
    RUBY
      dd_show('sdef_then_sdef self') { Game::Party.run_m }
      dd_show('sdef_then_sdef explicit') { Game::Party.m }
    RUBY
    # `def self.m`, then `class << self` redefines it
    Form.new(name: 'sdef_then_sclass_def', names: %w[m], owners: %w[Game::States.singleton], program: <<~'RUBY', driver: <<~'RUBY'),
      module Game
        class States
          def self.m; 1; end
          class << self
            def m; 2; end
          end
          def self.run_m; m; end
        end
      end
    RUBY
      dd_show('sdef_then_sclass_def self') { Game::States.run_m }
      dd_show('sdef_then_sclass_def explicit') { Game::States.m }
    RUBY
    # module_function over a def that is redefined afterwards, and `def self.f` before module_function
    Form.new(name: 'module_function_double', names: %w[helper f], owners: %w[RGSS.singleton], program: <<~'RUBY', driver: <<~'RUBY'),
      module RGSS
        def helper; 1; end
        module_function :helper
        def helper; 2; end
        def self.run_helper; helper; end
        def self.f; 1; end
        def f; 2; end
        module_function :f
        def self.run_f; f; end
      end
    RUBY
      dd_show('module_function_double copy self') { RGSS.run_helper }
      dd_show('module_function_double copy explicit') { RGSS.helper }
      dd_show('module_function_double over sdef self') { RGSS.run_f }
      dd_show('module_function_double over sdef explicit') { RGSS.f }
    RUBY
  ].freeze

  OWNERS = FORMS.flat_map(&:owners).uniq.freeze

  def self.program(forms = FORMS)
    (forms.map { |f| f.rename(f.program) } + forms.map { |f| f.late && f.rename(f.late) }.compact).join("\n")
  end

  DRIVER_HEAD = <<~'RUBY'
    def dd_show(label)
      v = yield
      puts "#{label}: #{v}"
    rescue => e
      puts "#{label}: raised #{e.class}"
    end
  RUBY

  def self.driver(forms = FORMS)
    "#{DRIVER_HEAD}#{forms.map { |f| f.rename(f.driver) }.join}puts 'end'\n"
  end

  # [form, class expression, method, compiled?]: what the registration leaves for a name once the class
  # bodies have run. A kept last `def` is a compiled entry; a withdrawn group, an alias and an attr_reader
  # are not.
  PROBES = [
    ['attr_then_def', 'Game::Screen', 'v', true], ['def_then_def', 'Game::Troop', 'v', true],
    ['triple_def_raises', 'Game::EnemyAi', 'v', true], ['reopened_class', 'Game::Enemy', 'v', true],
    ['define_method_then_def', 'Game::Shop', 'v', true], ['live_def_raises', 'Game::Transition', 'v', true],
    ['call_between', 'Game::Interpreter', 'v', true], ['private_visibility', 'Game::TextReveal', 'w', true],
    ['super_into_double', 'Game::NumberInput', 'v', true], ['alias_over_def', 'Game::Party', 'b', false],
    ['alias_over_def', 'Game::Party', 'c', false], ['conditional_def', 'Game::Actor', 'v', false],
    ['conditional_def', 'Game::Actor', 'w', false], ['sdef_then_sdef', 'Game::Party.singleton_class', 'm', true],
    ['sdef_then_sclass_def', 'Game::States.singleton_class', 'm', true],
    ['singleton_vs_instance_symbol', 'Game::Battle', 'singleton_make', true],
    ['singleton_vs_instance_symbol', 'Game::Battle.singleton_class', 'make', true]
  ].freeze

  def self.probes(forms = FORMS)
    PROBES.select { |form, *| forms.any? { |f| f.name == form } }.map do |form, klass, name, want|
      f = forms.find { |x| x.name == form }
      [form, klass, f.names.include?(name) ? "#{name}_#{form}" : name, want]
    end
  end

  def self.probe(forms = FORMS)
    lines = probes(forms).map { |_form, klass, name, _want| "puts \"#{klass} #{name}: \#{dd_compiled?(#{klass}, :#{name})}\"" }
    "#{lines.join("\n")}\nputs 'end'\n"
  end

  PROGRAM = program
  DRIVER = driver
end
