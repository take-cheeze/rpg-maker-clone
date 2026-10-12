# Generated register declarations

Ordinary compiled methods and fallback block functions initialize argument
registers directly from their parameters. Native arguments use the same boxing
operations and parameter order as before; rest, optional and explicit block
slots retain their existing positions. Other registers still start as nil.

After the method body is emitted, bc2cpp drops nil-only declarations whose
register identifier occurs nowhere else in that body. Address-taken registers
and references in exception or block glue are retained. The scan also counts
comments and string literals, so it can conservatively retain extra declarations.
It does not remove assignments or perform bytecode liveness analysis.
Resumable methods keep their separate frame-based register assembly.

For a local full-world rpg2k generation, this removed 7,520 lines and 229,623
bytes (1.2% of the original source). This is a source reduction; optimized
binary size and compile-time benefits depend on the C++ compiler.

`scripts/bc2cpp/arg_shapes_check.rb` compares interpreted and compiled arguments,
conditional nil locals and captured locals. Its native-argument case checks
fixnum, float and bool boxing. The full compiled-core mruby suite checks the
remaining core methods and Fiber behavior.
