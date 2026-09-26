bc2cpp: resolve a construct receiver against the classes the world DEFINES

`lexically_resolve_construct_target` decided only which class a written name
denoted, but it searched `DIRECT_CONSTRUCT_TARGETS` -- the admission list --
rather than the set of classes that exist. So a bare `Window.new` inside
`class RPG2k` resolved to nothing, not because the name is ambiguous but because
the resolver's table was the wrong one. `Window` has two bindings program-wide
(RGSS::Window in mruby-rgss/mrblib/lib.rb:1019, RPG2k::Window in
mruby-rpg2k/mrblib/main.rb:26), so UniqueClassNames refuses it outright, yet
inside `module RPG2k` only RPG2k::Window is reachable -- mruby-rpg2k's own
comment records that "Every use is inside `class RPG2k`, so the bare name still
resolves here".

`ConstructClassNames` (new) holds the fully-qualified class/module names the
closed world defines, built from the same CLASS/MODULE walk UniqueClassNames
uses so the two agree on what the bytecode defines. A statement whose outer
scope cannot be recovered is recorded as :unknown and EXCLUDED, since a name
that might not exist must not resolve.

The two tables are kept separate on purpose. RESOLUTION now decides only WHICH
class a name denotes, which is a fact about the program. ADMISSION stays with
compile_send's four live gates: no custom `self.new`/`self.allocate`, an
#initialize that compiles clean with pure mandatory arity, a matching argument
count, and the owner being emitted. Listing a class in
DIRECT_CONSTRUCT_TARGETS therefore still grants nothing -- it only stops the
resolver from looking -- so widening the resolution cannot produce an unsound
call: a class failing any gate simply stays dynamic.

Verified on the resolver directly, which now refuses where the name is not
lexically visible:

  Window      inside RPG2k::Scene::Menu -> RPG2k::Window
  Window      inside RPG2k              -> RPG2k::Window
  Window      inside Game::Party        -> nil
  Scene::Menu inside RPG2k              -> RPG2k::Scene::Menu
  Viewport    inside RPG2k::Scene::Map  -> nil
  Vehicle     inside Game::State        -> Game::Vehicle

Measured on the hot-only wio closed world, full compilation, core mrblib in the
world, BC2CPP_NO_ONLY_OWNERS=1 -- tracing every `:new` site's own four gates:

  the 552 sites that resolve to a known class but were unlisted break down as
    207  #initialize is not pure-mandatory (has optional args)
     69  no #initialize at all (Array, StringIO, Viewport, ...)
     68  PASS every gate -- just not listed
     52  #initialize does not compile clean (LCF::Array1D)

So the lexical resolution is correct and worth having, but it converts only the
68. `RPG2k::Window` alone is 168 sites and every one has
`def initialize(x = 0, y = 0, width = 0, height = 0)`, whose optional arguments
are exactly what the pure-mandatory gate refuses; `dispatch_targets.rb`'s own
comment already predicted this ("Classes whose #initialize has `= default`
arguments and no keywords (Game::Vehicle, Game::Character, ...) are omitted: they
could never fire"). Net: POLY 2353 -> 2365, TYPED 530 -> 615, MONO 2037 -> 2025,
generated C++ 18,535,167 -> 18,514,504 bytes.

The 68 are the classes worth listing: RPG2k::Scene::Map::LRUBitmapCache (21),
LCF::Array2D (20), Game::Message::PauseMarker (15), RPG2k::Scene::SaveLoad (12),
Game::Message::SpeedMarker (9), Game::Message::Segment (9), and the request /
state record classes. That is left as the next step rather than done here, so
this commit carries only the resolution change and its measurement.

scripts/bc2cpp_*_check.rb: 44 pass, 5 fail -- the same 5 that fail at the commit
this branch started from.
