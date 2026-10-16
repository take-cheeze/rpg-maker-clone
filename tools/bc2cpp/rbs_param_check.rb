# frozen_string_literal: true

require 'set'
require_relative 'call_site_index'
require_relative 'dynamic_names'

# RBS_CHECKED_PARAMS (docs/adr/0456): a class parameter type in an RBS signature is a checked fact, not a seed.
#
# `def m: (Game::State s) -> R` on a method the program defines feeds ClassAnnotations (the receiver class of `s`
# inside the body). Before this check nothing compared it with the callers. Now, for every such parameter:
#
#   * the name must have a single definition (MONO) whose every caller the closed world sees: a POLY name, a
#     name a computed send can reach (DynamicNames.universe, ADR 0279), a name an outside-world source spells
#     (natives and foreign Ruby can call it with anything), a packed (`f(*a)`, `f(*a, &b)`) or keyword caller
#     refuses the declaration (TC1014 at the signature); a name nothing calls holds vacuously;
#   * every argument at a call site the closed world resolves to the definition must trace to the declared class
#     through the reaching definitions of its register: `Klass.new` (an unoverridden constructor of exactly that
#     class), a call whose every definition declares that class as its non-optional return, a parameter of the
#     enclosing method whose signature declares that class, or `self` in a method of a class nothing inherits
#     from. Anything else is TC1013 at the call site's file:line.
#
# A refused or unverified parameter is removed from the annotation tables, so a type check run (which does not
# abort on errors) still never trusts it. Integer / Symbol / Array / Hash parameters are not checked here: their
# consumers re-check the value (ADR 0413's embedded-SETIV TypeError and mrb_array_p tripwires).
module RbsParamCheck
  MAX_DEPTH = 8

  module_function

  # loaded: RbsSignatures.load's result; class_annotations: the merged table RbsSignatures.apply filled;
  # comment_class_args: label -> args the `# bc2cpp:` comments gave (they win and are not checked here).
  # Returns [diagnostics, verified] where verified is a Set of [label, position].
  def check(loaded, ireps, registry, class_annotations, comment_class_args:, call_sites:, outside_tokens:,
            superclass_of:, display_root: nil, applied: nil)
    ctx = context(loaded, ireps, registry, superclass_of)
    ctx.merge!(outside: outside_tokens, display_root: display_root, call_sites: call_sites, applied: applied,
               class_annotations: class_annotations, comment_class_args: comment_class_args)
    diags = []
    pending = targets(ctx)
    pending.each do |sig, d, positions|
      refusal = refusal_of(ctx, sig, d)
      next unless refusal

      positions.each { |pos, _cls| drop(ctx, d.irep, pos) }
      listed = positions.map { |p, c| "#{p + 1} (#{c})" }.join(', ')
      diags << diag(sig.loc.file, sig.loc.line, sig.loc.col, 'TC1014',
                    "#{sig.owner}##{sig.name}: parameter type(s) #{listed} refused, not trusted: #{refusal}")
    end
    # A caller's own declared parameter only proves an argument while it is itself kept, so drop to a fixed point.
    loop do
      dropped = false
      pending.each do |sig, d, positions|
        positions.each do |pos, cls|
          next unless kept?(ctx, d.irep, pos, cls)

          bad = unproven_sites(ctx, sig, d, pos, cls)
          next if bad.empty?

          dropped = true
          drop(ctx, d.irep, pos)
          bad.each do |irep, idx, why|
            diags << diag(display(ctx, irep.file), irep.instructions[idx].lineno.to_i, 1, 'TC1013',
                          "#{sig.owner}##{sig.name} parameter #{pos + 1}: argument not proven #{cls} (#{why}); " \
                          "declared at #{sig.loc.file}:#{sig.loc.line}")
          end
        end
      end
      break unless dropped
    end
    verified = pending.flat_map do |_sig, d, positions|
      positions.filter_map { |pos, cls| [d.irep, pos] if kept?(ctx, d.irep, pos, cls) }
    end
    [diags, verified.to_set]
  end

  def diag(file, line, col, code, message)
    RbsSignatures::Diag.new(file: file, line: line, col: col, severity: 'error', code: code, message: message)
  end

  # The tables every query reads: method owners (`self_of` only for def bodies, never blocks, whose self an
  # instance_exec may change; `owner_of` also for blocks, for lexical constant lookup) and the signature of each body.
  def context(loaded, ireps, registry, superclass_of)
    ctx = { ireps: ireps, registry: registry, subclassed: superclass_of.values.grep(String).to_set,
            dynamic: DynamicNames.universe(ireps), self_of: {}, owner_of: {}, sig_of: {}, def_of: {} }
    defs_by = {}
    registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep

        ctx[:self_of][d.irep] = d.owner
        defs_by[[d.owner, d.name.to_s]] = d
      end
    end
    ctx[:owner_of].merge!(ctx[:self_of])
    parent = {}
    ireps.each_value { |irep| (irep.reps || []).each { |child| parent[child] = irep.label } }
    ireps.each_key do |label|
      up = label
      up = parent[up] until up.nil? || ctx[:self_of].key?(up)
      ctx[:owner_of][label] ||= ctx[:self_of][up] if up
    end
    loaded.methods.each_value do |sig|
      d = defs_by[[sig.owner, sig.name]] or next
      ctx[:sig_of][d.irep] = sig
      ctx[:def_of][d.irep] = d
    end
    ctx
  end

  # [irep, index, why] for every caller whose argument at `pos` is not proven `cls`. A caller whose argument count
  # the definition cannot take raises ArgumentError before the body runs, so it proves nothing and needs nothing.
  def unproven_sites(ctx, sig, d, pos, cls)
    req, opt, rest = ctx[:ireps][d.irep].enter&.enter_fields&.first(3)&.map(&:to_i) || [0, 0, 0]
    callers(ctx, sig.name).filter_map do |irep, idx, dest, argc|
      next if argc < req || (rest.zero? && argc > req + opt)

      why = trace(ctx, irep, idx, (dest + pos + 1).to_s, cls, 0)
      [irep, idx, why] if why
    end
  end

  # Still a signature-only class fact (a `# bc2cpp:` comment is an unchecked hint, never a proof).
  def kept?(ctx, label, pos, cls)
    ctx[:class_annotations][label]&.args&.[](pos) == cls && !ctx[:comment_class_args][label]&.[](pos)
  end

  # [sig, def, [[position, class], ...]] for every signature whose class parameter reached ClassAnnotations.
  def targets(ctx)
    out = []
    ctx[:sig_of].each do |label, sig|
      d = ctx[:def_of][label]
      ann = ctx[:class_annotations][label]
      positions = sig.args.each_with_index.filter_map do |type, i|
        next unless type.kind == :class && ann && ann.args[i] == type.cls
        next if ctx[:comment_class_args][label]&.[](i)

        [i, type.cls]
      end
      out << [sig, d, positions] unless positions.empty?
    end
    out
  end

  def refusal_of(ctx, sig, d)
    name = sig.name
    defs = ctx[:registry].fetch(name, [])
    return "#{name} has #{defs.size} definitions (POLY): a call site may reach another one" if defs.size != 1
    if ctx[:dynamic].include?(name)
      return "#{name} is a name a computed send can reach (a Symbol or String literal of it)"
    end
    if ctx[:outside].include?(name)
      return "#{name} is spelled by an outside-world (native or foreign Ruby) source, which may call it"
    end

    irep, idx, = callers(ctx, name).find { |_irep, _idx, _dest, argc| argc.nil? }
    "a packed (splat) or keyword caller at #{display(ctx, irep.file)}:#{irep.instructions[idx].lineno}" if irep
  end

  def callers(ctx, name)
    CallSiteIndex.sites(ctx[:call_sites], name)
  end

  # Removes the parameter's class seed, and its IR contract (ADR 0441), so nothing downstream reads it.
  def drop(ctx, label, pos)
    if (applied = ctx[:applied])
      [applied.ir_arg_types, applied.ir_arg_elements].each do |table|
        table[label] = table[label].except((pos + 1).to_s).freeze if table[label]
      end
    end
    ann = ctx[:class_annotations][label] or return
    args = ann.args.dup
    args[pos] = nil
    ctx[:class_annotations][label] = ann.class.new(args: args)
  end

  def display(ctx, file)
    root = ctx[:display_root]
    root && file ? file.sub(%r{\A#{Regexp.escape(root)}/?}, '') : file.to_s
  end

  # nil when every definition of `reg` reaching instruction `idx` is proven `cls`, else why not.
  def trace(ctx, irep, idx, reg, cls, depth)
    return 'trace depth' if depth > MAX_DEPTH

    defs = BytecodeIR.reaching_definitions(irep, idx, reg)
    return 'the reaching definitions are not computable here' if defs.nil? || defs.empty?

    defs.each do |definition|
      why = if definition.entry? then entry_why(ctx, irep, definition.reg, cls)
            else writer_why(ctx, irep, definition, cls, depth)
            end
      return why if why
    end
    nil
  end

  def entry_why(ctx, irep, reg, cls)
    sig = ctx[:sig_of][irep.label]
    return "R#{reg} is a block parameter or upvar" unless sig

    type = reg.to_i.positive? ? sig.args[reg.to_i - 1] : nil
    return nil if type && type.kind == :class && type.cls == cls && kept?(ctx, irep.label, reg.to_i - 1, cls)

    "parameter #{reg} of #{sig.owner}##{sig.name} is declared #{type&.text || 'untyped'}"
  end

  def writer_why(ctx, irep, definition, cls, depth)
    insn = irep.instructions[definition.index]
    case insn.op
    when 'LOADSELF'
      owner = ctx[:self_of][irep.label]
      return nil if owner == cls && !ctx[:subclassed].include?(cls)

      "self (#{owner || 'in a block'})"
    when 'SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB'
      name = insn.sym
      return new_why(ctx, irep, definition.index, cls) if name == 'new' && insn.op.start_with?('SEND')

      returns_why(ctx, name, cls)
    else
      "#{insn.op} at #{display(ctx, irep.file)}:#{insn.lineno}"
    end
  end

  # `Klass.new(...)` of exactly `cls`, whose `new` nothing in the program overrides.
  def new_why(ctx, irep, idx, cls)
    overrides = ctx[:registry].fetch('new', []).reject { |d| d.owner == '<native>' }
    return "#{overrides.map(&:owner).join(', ')} define new" unless overrides.empty?

    owner = ctx[:owner_of][irep.label]
    found = trace_new_target(irep, idx + 1, irep.instructions[idx].reg, {}, 0, nil, owner: owner)
    found == cls ? nil : "`new` of #{found || 'an unresolved constant'}"
  end

  def returns_why(ctx, name, cls)
    defs = ctx[:registry].fetch(name, [])
    return "a call to #{name}, which the program does not define" if defs.empty?

    defs.each do |d|
      sig = d.irep && ctx[:sig_of][d.irep]
      ret = sig&.ret
      next if ret && ret.kind == :class && ret.cls == cls

      return "#{d.owner}##{name} does not declare -> #{cls}"
    end
    nil
  end
end
