# Sharded generated C++ (BC2CPP_SHARDS)

`tools/bc2cpp/bc2cpp.rb` writes a whole closed world's compiled methods as one C++ text. Compiled as one translation
unit it is the slowest object of every bc2cpp build: the optcarrot probe's is 92K lines, 80 s at `-O3` on one core,
and three quarters of that is GCC optimizing its thousands of functions one after another. `BC2CPP_SHARDS=N` splits
the text into N translation units that the build compiles in parallel. The generated code is the same code; only
where each function's definition lives changes.

## Files

With `BC2CPP_SHARDS=N` (N > 1) a run writes, for `OUT_SYMBOL=<symbol>`:

* stdout, the build's `<symbol>_gen.cpp`: the prelude (helpers, caches, tables, registration, forward declarations),
  the `SHARD_DECLS` block, then shard 0's methods and the gem hooks inside `#ifndef BC2CPP_SHARD_PRELUDE_ONLY`;
* `OUT_DIR/<symbol>_gen_shard<k>.cpp`, k = 1...N-1: `#define BC2CPP_SHARD_PRELUDE_ONLY`, `#include "<symbol>_gen.cpp"`,
  then shard k's methods.

Every shard file is written, even one with no methods (a comment), so a build lists N objects without reading the
output. A gem with less than `ShardOutput::MIN_SHARD_BYTES` (400 KB) of method code per shard uses fewer shards; one
that fits in a single shard gets exactly the `BC2CPP_SHARDS=1` text, byte for byte. The default is 1 for bc2cpp.rb
itself, so the fixture checks, which read the one generated text, see what they always did. A run with a
`BC2CPP_TRACE_*` instrumenter writes one unit and comment-only shards, since the instrumenters rewrite one text.

## One definition of everything

The prelude is compiled into every shard. Its file-scope `static` state would then exist once per shard: the frame
stacks for `break`/`return`, the symbol, class and constant caches, the method cache epoch, the `mrb_data_type`
tables whose address `DATA_PTR` checks compare. So `ShardOutput` (`tools/bc2cpp/shard_output.rb`) rewrites the prelude
(SHARD_SINGLE_DEFINITION):

* it goes inside `namespace bc2cpp_shard_<symbol>` (with a `using` directive), which keeps two gems' same-named
  helpers (`bc2cpp_sym`, `bc2cpp_cconst_12`, ...) apart;
* every file-scope variable, every function holding a mutable function-local static or whose address is taken, and
  every static function such a function calls becomes `inline`: a C++17 inline function or variable has one
  definition in the program, and an inline function's local statics one instance (`shared_prelude_items`);
* every other `static` function stays `static` (marked `[[maybe_unused]]`, as a shard need not call it): it is
  stateless, so each shard's own copy is the same function. Making these `inline` too costs GCC the freedom to drop
  their out-of-line bodies, and moved its inlining decisions enough to cost 2.4 % per frame on the probe;
* `#include` lines stay at global scope (an `#include` inside an `#if` region goes first, with the region's
  directives, and the region follows in the namespace);
* the declarations of method-section functions (`Foo_impl`, the registered `Foo` entries) stay global, as their
  definitions are, and so does an external prelude function another gem links to (DIRECT_CONSTRUCT_ACCESSORS'
  `<Owner>_compiled_class`): its definition is the main file's alone, and the shards see its declaration.

In the methods section, a `static` function that the prelude or another shard names loses `static` and is declared
in `SHARD_DECLS`; its name carries its owner and method, so it is unique in the program. Every other `static` there
stays file-local. A name defined in two shards, or a stateful prelude `static` that would have to stay beside a
method declaration, stops the run with an error; a declaration missing from a shard fails its compile, and a second
strong definition fails the link, so a generator change cannot silently duplicate state.

## Grouping

Methods are grouped by owner class (an owner's methods call each other most, so most direct calls stay inside one
translation unit where GCC can inline them), and owners are placed largest first onto the lightest shard.

## Builds

* The compiled engine gems (`mruby-*-compiled/mrbgem.rake`) call `bc2cpp_compiled_gem_shards`
  (`tools/bc2cpp/compiled_gems.rb`): shards 1...N-1 are objects of the gem, compiled from the gem build directory
  next to `register.cxx` (which includes shard 0). `BC2CPP_SHARDS` defaults to 4 there; a stamp file holding N is a
  prerequisite of the generated file, so changing N regenerates.
* The optcarrot probe (`tools/optcarrot_probe/compiled_run.rb`) defaults to 4 and copies the shard files into the
  probe gem's `src/`. Its generated main file lives in `gem/generated/`, outside `src/`: mruby compiles every file in
  a gem's `src/`, and the probe used to compile `optcarrot_probe_gen.cpp` twice, once alone (an object nothing
  linked) and once included by `register.cxx`. The probe's rake also runs with `-m`; without it rake runs every file
  task in turn and `-j` schedules nothing.

Shards are ordinary objects, so every toolchain (native, Emscripten, PSP, Wio) takes them without a flag.

## Measurements

The optcarrot probe on a shared 4-core box, GCC 13, `-O3`, master `d645f623`; per frame is callgrind instructions
over frames 1 to 21, checksum 59662 at 180 frames in every build.

| | generated-code compile | per frame |
|---|---|---|
| one unit, alone | 80.7 s | 29.697 M |
| one unit in the build, libraries already built | 90.6 s, 89.8 s | |
| LTO: the unit with `-flto`, then `-flto=4` link | 16.2 s, then 24–32 s at link (66 s CPU) | −0.2 % against the same flags |
| `BC2CPP_SHARDS=4`, each shard alone | 27.6, 19.5, 22.3, 25.7 s | 29.746 M (+0.16 %) |
| `BC2CPP_SHARDS=4` in the build, libraries already built | 28.5 s, 26.6 s | |

A whole probe build from an empty mruby build directory went from about 6.6 minutes (serial rake, the generated file
compiled twice) to 197 s with `-m` and one unit, and 188 s with four shards, about 55 s of each being bc2cpp itself
and 25 s the benchmark runs; with `-m` that build is bound by its library objects and the shards end with them.
The closed-world engine build (`scripts/bc2cpp/closed_build.bash`, `-O0`) recompiles its four compiled gems in 31.6 s
with four shards against 82.9 s with one.

LTO (`-flto` on the generated unit, `-flto=auto` at link) keeps whole-program inlining and its LTRANS partitions run in
parallel, but its serial front end and the link-time code generation run after every other object, so the critical
path stays near 45 s, against under 28 s for four shards that start with the library objects. It also needs an
LTO-aware link of `libmruby.a` in every consumer (CMake, pspdev, PlatformIO) and an archiver that indexes LTO objects,
and is pointless in the `-O0` closed build. Sharding was chosen.

The check is `ruby scripts/bc2cpp/shard_output_check.rb`: the text rewrite, a split synthetic program whose prelude
state must be one instance across shards, and a real `BC2CPP_SHARDS=2` generation run against the interpreter.
