# frozen_string_literal: true

require_relative 'compiled_gems'

# CodeGen: ENTRY_ARG_CLASS_POOL (ADR 0282).
#
# The receiver-dispatch sibling of NUMERIC_ENTRY_ARG_PROOF: an argument register
# holds the class EVERY call site that can reach the method passes there. Admission
# is ENTRY_ARG_CALLSITE_PROOF's (entry_arg_candidates: one definition, every
# outside source silent about the name, every site visible) plus the refusals
# below. Two tables, one fixpoint each:
#
#   * exact: every site's class is proven without a guard (a fresh `Klass.new`,
#     a NumericFlow class set, or the caller's own exact parameter). A receiver
#     that is such a parameter dispatches without a guard (exact_pooled_entry_class).
#   * hint: the sites are traced the way a guarded receiver is
#     (trace_new_target, guarded), so ClassLayout ivar hints count; a guarded
#     consumer keeps its runtime class check (JoinDominance.entry_class).
#
# Both are greatest fixpoints: hypotheses come from the sites that prove, then any
# key with a site that fails under the current table is dropped until stable. That
# admits recursion (a site passing the caller's own parameter) and is sound by
# induction over the calls of one run: the first call to a method comes from a site
# that proves without the hypothesis, and every later call passes what an earlier
# call received.
class CodeGen
  # Namespaces a game script can name: the RGSS API, the core classes, and Object
  # (whose methods every receiver answers). A method defined there can be called
  # by name from code the compiler never sees, so its arguments are unpooled.
  CLASS_POOL_SCRIPT_ROOTS = (%w[RGSS Object Kernel BasicObject Module Class Comparable Enumerable] +
                             BC2CPP_CORE_OWNERS.map { |o| o.delete_suffix('.singleton').split('::').first }).to_set.freeze

  # NumericFlow class sets that name exactly one class.
  CLASS_POOL_MASK_CLASSES = { NumericFlow::INT => 'Integer', NumericFlow::FLT => 'Float', NumericFlow::ARR => 'Array',
                              NumericFlow::HSH => 'Hash', NumericFlow::STR => 'String' }.freeze

  def compute_entry_arg_classes
    @entry_arg_class_exact = {}
    @entry_arg_class_hint = {}
    cand = class_pool_candidates
    return if cand.empty?

    @entry_arg_class_exact = class_pool_fixpoint(cand) do |irep, idx, reg, owner, table|
      class_pool_exact_fact(irep, idx, reg, owner, table)
    end
    hint = class_pool_fixpoint(cand) do |irep, idx, reg, owner, table|
      class_pool_hint_fact(irep, idx, reg, owner, table)
    end
    @entry_arg_class_hint = hint.transform_values(&:first)
  end

  # The pooled hint table, or nil when there is none (the tracer then adds nothing).
  def entry_arg_class_hints
    @entry_arg_class_hint.nil? || @entry_arg_class_hint.empty? ? nil : @entry_arg_class_hint
  end

  def class_pool_script_visible?(owner)
    return true unless owner.is_a?(String)

    CLASS_POOL_SCRIPT_ROOTS.include?(owner.delete_suffix('.singleton').split('::').first)
  end

  # A call whose arguments are exactly its `n` positionals: a keyword pair or a
  # splat moves where a trailing Hash or an optional slot gets its value.
  def class_pool_plain_site?(insn)
    insn.n_spec && insn.n_spec != '*' && (insn.nk_spec.nil? || insn.nk_spec == '0')
  end

  # (irep label, argument register) -> [sites, k]. Rules 1-8 of
  # ENTRY_ARG_CALLSITE_PROOF, with optional positionals allowed (a site passing
  # fewer leaves the default in place) and rest/post/keywords refused, plus:
  # no computed-name `send` could name it, and no script can call it.
  def class_pool_candidates
    return {} unless @foreign_method_names && @outside_tokens

    sites, poisoned = entry_arg_call_index
    cand = {}
    @registry.each do |name, defs|
      next unless defs.size == 1
      next if @foreign_method_names.include?(name) || @outside_tokens.include?(name)
      next unless name =~ /\A[A-Za-z_]/
      next if name == 'initialize' || poisoned.include?(name) || numeric_dynamically_named?(name)

      d = defs.first
      next unless d.irep && !class_pool_script_visible?(d.owner)

      irep = @ireps[d.irep]
      next unless irep

      mand, opt, rest, post, kw, kdict = irep.enter ? irep.enter.enter_fields : [0] * 6
      next unless rest.zero? && post.zero? && kw.zero? && kdict.zero?

      total = mand + opt
      here = sites[name]
      next if total.zero? || here.empty?
      next unless here.all? { |(ir, i, _recv, argc, _own)| argc.between?(mand, total) && class_pool_plain_site?(ir.instructions[i]) }

      (1..total).each { |k| cand[[d.irep, k]] = [here, k] }
    end
    cand
  end

  # [class, nilable] joined over the sites that pass argument +k+, or nil when a
  # site is unprovable or two sites disagree. A site whose only value is nil adds
  # nilability and no class.
  def class_pool_join(sites, k, table, &prover)
    classes = []
    nilable = false
    sites.each do |(irep, idx, recv, argc, owner)|
      next if argc < k

      fact = prover.call(irep, idx, (recv + k).to_s, owner, table)
      return nil unless fact

      classes << fact[0] if fact[0]
      nilable ||= fact[1]
    end
    classes.uniq!
    classes.size == 1 ? [classes.first, nilable] : nil
  end

  def class_pool_fixpoint(cand, &prover)
    table = {}
    loop do
      changed = false
      cand.each do |key, (sites, k)|
        next if table.key?(key)

        classes = []
        nilable = false
        sites.each do |(irep, idx, recv, argc, owner)|
          next if argc < k

          fact = prover.call(irep, idx, (recv + k).to_s, owner, table)
          next unless fact

          classes << fact[0] if fact[0]
          nilable ||= fact[1]
        end
        classes.uniq!
        next unless classes.size == 1

        table[key] = [classes.first, nilable]
        changed = true
      end
      break unless changed
    end
    loop do
      changed = false
      table.keys.each do |key|
        sites, k = cand[key]
        joined = class_pool_join(sites, k, table, &prover)
        cls, nilable = table[key]
        if joined.nil? || joined[0] != cls
          table.delete(key)
          changed = true
        elsif joined[1] && !nilable
          table[key] = [cls, true]
          changed = true
        end
      end
      break unless changed
    end
    table
  end

  # NumericFlow's class set as [class, nilable]; nil when it names no single class.
  def class_pool_mask_fact(mask)
    return nil if mask.nil? || mask.zero? || mask.anybits?(NumericFlow::OTHER)

    nilable = mask.anybits?(NumericFlow::NIL)
    rest = mask & ~NumericFlow::NIL
    return [nil, true] if rest.zero?

    cls = CLASS_POOL_MASK_CLASSES[rest]
    cls ? [cls, nilable] : nil
  end

  # Unguarded: a class set, a fresh `Klass.new` that dominates the read, or the
  # caller's own exact parameter.
  def class_pool_exact_fact(irep, idx, reg, owner, table)
    fact = class_pool_mask_fact(numeric_raw_mask(irep, idx, reg, owner))
    return fact if fact

    enter = irep.enter
    mand = enter ? enter.enter_fields.first : 0
    klass = trace_new_target(irep, idx, reg, @class_layout[owner.owner], mand, @class_annotations[irep.label]&.args,
                             owner: owner.owner, class_layout: @class_layout, registry: @registry,
                             container_constants: @container_constants, known_owners: @known_owners,
                             dominated: JoinDominance.new(irep))
    if klass && exact_new_receiver_class(irep, idx, reg, owner: owner.owner, expected_class: klass)
      return [klass, false]
    end

    class_pool_own_parameter(irep, idx, reg, owner) { |key| table[key] }
  end

  # The caller's parameter the register still holds (no write on the way that
  # could differ), read through +block+ with the [label, position] key.
  def class_pool_own_parameter(irep, idx, reg, owner)
    return nil unless owner.irep == irep.label

    enter = irep.enter
    mand = enter ? enter.enter_fields.first : 0
    entry = irep.walk_dominating_writers(idx - 1, reg.to_s, use: idx, follow_moves: true, exhausted: ->(last) { last }) { nil }
    return nil unless entry && entry.to_i.between?(1, mand)

    yield [irep.label, entry.to_i]
  end

  # Guarded: the exact facts, then the trace a guarded receiver would run, with
  # the hypothesis table visible to it (own parameters).
  def class_pool_hint_fact(irep, idx, reg, owner, table)
    fact = class_pool_mask_fact(numeric_raw_mask(irep, idx, reg, owner))
    return fact if fact

    enter = irep.enter
    mand = enter ? enter.enter_fields.first : 0
    klass = trace_new_target(irep, idx, reg, @class_layout[owner.owner], mand, @class_annotations[irep.label]&.args,
                             owner: owner.owner, class_layout: @class_layout, registry: @registry,
                             container_constants: @container_constants, element_annotations: @element_annotations,
                             known_owners: @known_owners, capture_hints: @block_hash_capture_hints,
                             method_return_class: ->(method_name) { class_return_for_dispatch(method_name) },
                             guarded: true, entry_classes: table)
    klass ? [klass, false] : nil
  end

  # A receiver that is a parameter every call site fills with exactly +expected_class+
  # (never nil) needs no runtime class check.
  def exact_pooled_entry_class(irep, idx, reg, owner_def, expected_class)
    return nil if @entry_arg_class_exact.nil? || @entry_arg_class_exact.empty? || owner_def.nil?

    entry = class_pool_own_parameter(irep, idx, reg, owner_def) { |key| @entry_arg_class_exact[key] }
    entry && entry[0] == expected_class && !entry[1] ? expected_class : nil
  end

  # One line per fact, sorted, for the bc2cpp.rb diagnostic and the coverage report.
  def entry_arg_class_report
    lines = []
    { 'exact' => @entry_arg_class_exact, 'hint' => @entry_arg_class_hint }.each do |tier, table|
      (table || {}).each do |(label, k), fact|
        d = @owner_of[label]
        cls, nilable = Array(fact)
        lines << "  ARGCLASS #{tier} #{d ? "#{d.owner}##{d.name}" : "<irep #{label}>"} arg#{k} (#{cls}#{'|nil' if nilable})"
      end
    end
    lines.sort
  end
end
