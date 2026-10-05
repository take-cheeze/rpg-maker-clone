# 0359. The literal and `*rest` receiver proofs also hold inside compiled core bodies

Date: 2026-10-05

## Status

Accepted

## Context

EXACT_CORE_RECEIVER (ADR 0280) proves a receiver is exactly an Array, Hash, Range or String when a
dominating literal, or the method's own `*rest` slot, supplies it through register copies. The
proof read `@closed_world`, and a compiled core body (mruby's own Ruby, ADR 0264) is compiled with
`@closed_world` hidden, so every `args.size`, `hash.values` or `ary.empty?` on such a value in
`Array#dig`, `Hash#merge!`, `String#gsub`, `Range#first` and the like kept the inline Array/Hash/String
tag chain with a by-name send as its else.

Measured on the Wio shipped build (master 0a9adfc), `core_tag_chain_else:receiver_other` was 849
sites. The register-copy part of that category is not a lost copy chain: the exact-class flow
(ADR 0289) and the dominating walk already follow MOVEs. The receivers that stay unproven in engine
code are values of unknown origin (ivars with dropped pools, arguments, call results, element reads,
`x || []` merges). About 190 of the 849 sit in core bodies, and for some of them the receiver was a
literal or a rest array.

## Decision

`exact_core_value_class` and `exact_core_site` ask `exact_proof_world`: `@closed_world`, or
`block_core_world` (`@core_program_world`) inside a core body, the program-wide world NATIVE_CORE_DIRECT_REST
(ADR 0274) and the block arms already use for the same fact. Only the walk result counts there:
`exact_flow_core_class` and `frozen_table_exact_class` still need the engine world and answer nil for a
core body. `BC2CPP_CORE_BODY_EXACT=0` restores the old behaviour.

Soundness: "created by a literal / the rest slot" is "exactly that class" while nothing can give the
object a singleton class or mixin, which is `ClosedWorld#exact_instances_singleton_free?` of the
whole program (the same flag withdraws every engine proof). Core Ruby is the one source that scan
skips (ADR 0280); its only singleton-making sends are `instance_eval` on Enumerator, Lazy and socket
objects in `enumerator.rb`, `lazy.rb` and `socket.rb`, never on an Array, Hash, String or Range. The rest slot is
built fresh by every entry and every direct call. Dominance (loops, joins, rescue, captured writes) is
the same walk as for engine code, and the arms that consume the site keep their own lookup-safety checks.

## Consequences

Wio shipped build, same tree, switch off against on: `bc2cpp_send` call sites in generated bodies
2,408 to 2,368, `core_tag_chain_else:receiver_other` 849 to 804; 35 new CLOSED_WORLD_NATIVE_EXACT arms,
all in core bodies (`Array#dig`, `Hash#dig`, `Struct#dig`, `Hash#merge`, `String#gsub`/`sub`,
`Range#first`/`last`, `Enumerable#first`/`uniq`/`cycle`, `StringIO#read_nonblock`...). With the switch off
the shipped C++ is byte-identical to master. The receivers of unknown origin remain: they need new class
sources (ivar pools, argument pools, element classes), not more copy propagation.
