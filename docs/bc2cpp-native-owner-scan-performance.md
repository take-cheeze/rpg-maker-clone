# Native-owner scope scanning

The native-owner map identifies the function-local class variables used by
native method registrations. Its scope scan searches between braces rather
than visiting every character, reducing temporary character strings.

String and character literals are masked before the brace search. Match offsets
remain character offsets into the original source, including UTF-8 text. Nested
namespace and `extern "C"` blocks still recurse into their function bodies;
local owner resolution and malformed-block handling retain their existing rules.

`ruby scripts/bc2cpp/native_owner_scopes_check.rb` checks quoted and nested
braces, Unicode offsets, namespace recursion, local owners, parameters and
unclosed blocks. The host CI job and coverage reporter both run it.

## Local measurements

Against `ea368b23`, Ruby 4.0.5 + YJIT, building the owner map from 82 native
files three times after a warmup took 0.86 seconds before and 0.62 seconds after
(27% less time). Allocations fell from 6.90 million to 1.21 million (82% fewer).
All map fields were byte-identical, covering 683 names and 529 registrations.

Two alternating warm-cache whole-engine comparisons used the Wio source set,
all compiled owners, `BC2CPP_HOT_ONLY=0` and no hot-method list:

| Run | Baseline wall | Candidate wall | Baseline objects | Candidate objects |
| --- | ---: | ---: | ---: | ---: |
| 1 | 39.65 s | 41.07 s | 82.21 million | 78.42 million |
| 2 | 41.01 s | 40.15 s | 82.22 million | 78.42 million |

This removes about 3.8 million allocations per generation (4.6%). These
shared-host runs do not establish a consistent whole-generator elapsed-time
improvement. The first candidate run filled the invalidated scan cache and was
excluded. Generated C++ and diagnostics excluding timing lines were identical.
These generator measurements exclude base-RBS regeneration and C++ compilation.
