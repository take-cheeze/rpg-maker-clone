- **bc2cpp** now installs 402 previously-compiled-but-never-registered
  methods across `mruby-rpg2k-compiled` (35 new `BC2CPP_WIRED_EMBEDDINGS`
  owners), closing the registration gap `docs/adr/0188` found and
  `docs/adr/0186` had flagged for `Game::Actor` specifically. The entire
  map scene update/render loop (`RPG2k::Scene::Map`, 408/408), the full
  battle system (`Game::Battle`, 141/141; `RPG2k::Scene::Battle`, 174/174),
  actor/party data (`Game::Actor`, 124/124; `Game::Party`, 128/128), and
  seven menu scenes now run compiled instead of interpreted. Ten classes
  also gain real ivar-struct embedding as a side effect (`Game::Actor`,
  `Game::MessageConfig`, `Game::NumberInput`, `Game::Shop`, and six
  `RPG2k::Scene::*` menu classes), each independently verified safe
  against `pure_mandatory_arity?`/attr-collision rules before wiring.
  Verified: `scripts/bc2cpp_wired_embedding_check.rb` 100% on every new
  owner, coverage unchanged at 100.0% (0 `#error`), all 22
  `scripts/bc2cpp_*_check.rb` checks pass, a full `RPGMAKER_BC2CPP=1` host
  rebuild completes. See ADR 0190.
