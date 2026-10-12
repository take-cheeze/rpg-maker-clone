# 0422. Lower Optcarrot CPU dispatch in decoded bytecode

Date: 2026-10-13

## Status

Accepted

## Context

The Optcarrot probe previously rewrote CPU Ruby source into a static opcode
case. That exposes instruction calls but couples optimization to wrapper source
spelling and recompiles expanded Ruby. Compiler analyses need to observe every
introduced instruction call.

## Decision

Add an opt-in decoded-Irep rewrite before compiler registry and dataflow
construction. `BC2CPP_IR_CPU_DISPATCH=1` in the fixed Optcarrot probe suppresses
CPU source dispatch rewrites. Its compiler invocation acknowledges the fixed
native core with `BC2CPP_OPTCARROT_FIXED_CORE=1`; the pass refuses without that
contract. The contract also fixes normal benchmark method lookup: CPU instances
have no singleton replacements and methods are not installed dynamically during
the run. This is an experiment for this probe's known native core, not a proof
that arbitrary native extensions preserve core methods.

The pass recognizes the original `DISPATCH[@opcode]` splat construction, keeps
its `ARYCAT` coercion and copy, and inserts guarded literal calls. The newly
copied array has the core Array class. Guards compare length and compare a
literal Symbol with the name; they never call equality on an arbitrary name
object. Core Ruby replacements of length, equality or send withdraw the pass.
Exception handlers and branches entering the splat construction also refuse it.

The wrapper bodies keep their bytecode arithmetic and ivar operations. Their
fixed-argument computed sends receive guarded calls to CPU addressing,
instruction and storage methods. Every unmatched name, String name or unexpected
arity keeps the original send. Candidate names are optimization guesses, so
upstream additions retain their behavior through fallback. The registry is
rebuilt against the replacement graph before argument, ivar, escape and yield
analyses; no hidden synthetic calls are emitted late in code generation.

## Consequences

CPU dispatch and its nested computed sends can now be optimized without rewriting
or recompiling expanded source. The existing method inliner can consume eligible
replacement graphs, but larger wrappers exceed its conservative size limit.

This does not yet remove the splat Array copy or produce the former per-opcode
fully unfolded wrapper body. The runtime guards and larger graphs need benchmark
validation before replacing the faster source specialization by default.
