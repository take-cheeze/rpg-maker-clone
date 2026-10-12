# Bytecode IR method inlining

Enable the bounded method inliner with `BC2CPP_IR_INLINE=1`. mrbc compiles
each method independently; bc2cpp then expands eligible typed IR bodies
when emitting an already-resolved direct call. It does not produce a larger
Ruby method or serialize expanded bytecode.

```sh
BC2CPP_IR_INLINE=1 OPTCARROT_STATIC_PPU=1 OPTCARROT_STATIC_DISPATCH=1 \
  ruby tools/optcarrot_probe/compiled_run.rb 180
```

The Optcarrot target gains an `irinline` suffix, keeping the baseline binary
available for paired measurements. `BYTECODE_IR_INLINE` comments in generated
C++ identify expanded sites. Unset or `0` emits the ordinary call.

The first version admits only implicit-self, same-owner direct targets with
mandatory positional arguments. It keeps existing class checks and fallback
dispatch. Callee registers occupy a separate scope; arguments are captured
before that scope and returns leave it through a symbolic exit. Branches use
the decoded IR edges. Literal pools and proofs retain the callee's identity.

Bodies with blocks, handlers, upvars or unsupported opcodes, initializers,
core methods, direct recursion and unsafe Fiber reachability retain their
call boundaries. Resumable callers and native argument conversions are also
excluded. Size limits are 256 instructions, 128 registers, two nested
expansions and 512 added instructions per compiled method. These limits
control growth rather than promise a speedup.

Run `MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=path/to/build ruby
scripts/bc2cpp/method_inline_check.rb` for generation and native equivalence
checks. They cover local/argument isolation, loops, early returns, literals,
nested calls, refusal cases, disabled output equivalence and an IR branch
identity beyond 65,535. Inherited callers retain subclass overrides and
Fiber suspension is refused. CI runs the same native fixture and the
combined static CPU/synchronous PPU/IR-inline Optcarrot preset.

The bounded Optcarrot build expands 320 sites and installs the same 356
compiled methods. All 18 native full-state pairs agree across six bundled
games at 2, 180 and 1,800 frames. The pairs compare pixels, audio, RAM and
captured CPU/PPU registers. All 84 timing-run checksums also match.

On the shared Ryzen AI MAX+ 395 host, three initial pairs measured 0.5%
lower cold time, 1.5% lower fresh-batch time and 1.9% higher continuous FPS.
A follow-up with six 1,800-frame pairs alternated which binary ran first:
median time was 7.211 s without inlining and 7.129 s with it, about
249.6 versus 252.5 wall FPS (1.1%). This is a small measured effect, not
evidence of a large or general speedup. The `size` text column grows from
3,407,897 to 3,900,961 bytes (14.5%), reinforcing the opt-in scope.

See [ADR 0406](adr/0406-bytecode-ir-method-inlining.md).
