# 0226. Closed-world dead fallbacks fail the build unless reviewed

Date: 2026-09-24

## Status

Accepted

## Context

On the closed-world builds (psp, wio, maix), ADR 0210's `ClosedWorld` proves
some guard-chain fallbacks dead: no class in the build answers the name, so
the `else` arm can only raise `NoMethodError`. Those arms compile to
`bc2cpp_nomethod`, which raises at runtime exactly as dispatch would.

A dead fallback can mean one of two things:

- the arm is unreachable, because every class the receiver can have is
  already in the chain. This is the intended case.
- the receiver can have a class that answers nothing. That is a bug: a
  missing method, a typo, or a mis-modeled receiver. It raises in real play,
  and the runtime `rescue`s can hide it.

Nothing told these two cases apart, and nothing flagged a new site. A change
that turned a live call into a raise-only one compiled cleanly and shipped.
`STATIC_DISPATCH_UNREGISTERED` (ADR 0203) already solves the same kind of
problem: a checked-in list that the analysis re-proves on every run.

## Decision

A dead fallback is a build error by default. `tools/bc2cpp/nomethod_reviewed.rb`
holds `NOMETHOD_REVIEWED`, a `Set` of site keys, each in the form
`"<compiled owner>#<compiled method> -> <called name>"`. Owners are spelled as
in `STATIC_DISPATCH_UNREGISTERED` (`Foo.singleton` for class methods).
Several sites with the same called name inside one method share a key.

- `guarded_fallback_line` (codegen_send.rb) appends
  `/* CLOSED_WORLD nomethod: self|recv.<name> */` to every `bc2cpp_nomethod`
  it emits. The marker keeps the name after SymbolCache has rewritten the
  string into a table index.
- In closed-world mode, `bc2cpp.rb` lists every site on stderr
  (`== closed world nomethod sites ==`) and then `abort`s. This happens in
  the codegen task of the compiled gem, so the rake/CMake build fails, when:
  - a site's key is not listed (unreviewed), or
  - a listed key belongs to a method this run compiled and that method no
    longer has the site (stale). This check is skipped on hot-only runs.

  One run compiles only its own gem's owners, so staleness only covers
  methods the run compiled. A hot-only run (ADR 0214, which is every real
  psp/wio/maix build) skips the staleness check entirely. The chain at a
  call site depends on which callees are compiled. Under hot-only,
  `LCF::File#initialize` is compiled but its `schema`/`header` callees are
  not, so those sites keep their dispatch and are not dead fallbacks. The
  proof did not change, so the build must not fail over it. An unreviewed
  site still fails a hot-only build.
- `scripts/bc2cpp_nomethod_reviewed_check.rb` (CI `bc2cpp` job) reproduces
  the wio codegen of all three gems twice:
  - With every method compiled, the sites must equal `NOMETHOD_REVIEWED` in
    both directions. This catches any stale entry the per-gem build cannot
    see.
  - As the real hot-only build, with the gate enforced, bc2cpp.rb must
    succeed.

  It also tests the gate logic, and confirms that bc2cpp.rb aborts on a
  fixture's unreviewed site.
  `tools/bc2cpp/nomethod_reviewed_probe.rb` holds the run itself, including
  the wio gem list (no mruby-time since ADR 0221).
- `scripts/bc2cpp_nomethod_reviewed_update.rb [--write]` regenerates the
  list and prints the added and removed keys. Running `--write` does not
  count as a review.
- `BC2CPP_NOMETHOD_UNREVIEWED=allow` turns the abort into a warning. Only
  fixture worlds use it (`bc2cpp_closed_world_check.rb`, this check's own
  fixture), because their dead sites are the point of the test.

A reviewed site still emits the runtime `bc2cpp_nomethod`. Replacing it with
something the C++ compiler would reject cannot work, because the compiler
cannot see reachability. Dropping the arm would make the proof's premises
load-bearing for memory safety rather than for which exception gets raised.
One of those premises is ADR 0210's "a `self` receiver is kind_of its owner".
The out-of-line call costs a few bytes per site, and the gate is about
catching drift, not about saving size.

## Consequences

Measured with a host mrbc built from the pinned mruby plus the
`cmake/build-mruby.cmake` patches, running the wio codegen of each gem:

| gem | sites (all methods) | keys | sites (hot-only, as a real wio build) |
| --- | ---: | ---: | ---: |
| mruby-lcf-compiled | 13 | 5 | 0 |
| mruby-rpg2k-compiled | 39 | 33 | 0 |
| mruby-rgss-compiled | 0 | 0 | 0 |
| total | 52 | 38 | 0 |

Today the hot-only list (`tools/bc2cpp/hot_methods.txt`) compiles none of
these sites, so shipped psp/wio/maix firmware contains no `bc2cpp_nomethod`
at all. The gate starts to matter when the hot list grows. It also matters
on a `BC2CPP_HOT_ONLY=0` closed-world build, which compiles every site above
and runs the staleness check too.

ADR 0210 counted 17. ADR 0213 later removed `method_missing` from LCF, which
lets `LCF::File`'s own `self` calls convert, and more methods compile now.
The only `method_missing` class left in the closed world is
`RGSS::ErrorReport::Tee`, so the proof only converts sites whose receiver is
the compiled method's own `self`. All 52 sites are of that kind.

Every site was reviewed. For each one, the guard chain was read to confirm
that the enclosing class is in it, and the Ruby source was read to confirm
the definer. The enclosing class is always a definer, or a subclass that
INHERITED_GUARD lists. `self` is always an instance of the owner or of a
listed descendant, so the `else` arm cannot be reached. None of the sites
raises in play, and none hides a missing method. No bug was found, and no
Ruby source was changed.

| sites | receiver (`self` in) | called | definer |
| --- | --- | --- | --- |
| `LCF::File#initialize`/`#to_lcf` (13) | LCF::File and subclasses | `schema`, `header`, `terminate_root?` | `LCF::File` (abstract `raise`) and each of Database, MapTree, MapUnit, SaveData (lcf_file.rb) |
| `RPG2k::Scene::{Title,GameOver,Map,SaveLoad}#…` (14) | a `Scene::Base` subclass | `parent` | `Scene::Base` `attr_reader :parent` |
| `Scene::Base#state_display`, `Scene::Map#note_party_step` (2) | Scene::Base subclasses | `state_table` | `Scene::Base#state_table` |
| `RPG2k::Scene::Battle#…` (23) | Scene::Battle, RPG2k3::Scene::Battle | `advance_actor`, `enter_command_phase`, `open_battle_options`, `battle_commands`, `gauge_battle_layout?`, `drive_battle_command`, `prev_commandable_actor_index`, `finish_round_animation` | Scene::Battle, with overrides in `RPG2k3::Scene::Battle` (battle.rb, battle_rpg2k3.rb) |

The full key list is `NOMETHOD_REVIEWED` itself.

A new dead fallback now stops the psp/wio/maix build. The fix is one of:

- the site is a real bug: fix the Ruby;
- the analysis is too weak: improve it;
- after reading the site: add the key, by hand or with the update script.

The CI check costs one wio codegen run per gem, about 80 s each on the dev
container. The follow-up from ADR 0210 still applies: replacing
`RGSS::ErrorReport::Tee#method_missing` with explicit delegation would let
non-`self` receivers convert. Those receivers are where the proof could find
real missing-method bugs, and each new site would come through this gate.
