- The **Set Teleport Target** (11810), **Set Escape Target** (11830), **Change
  Encounter Rate** (11740), **Change System BGM** (10660) and **Change System
  SFX** (10670) event commands are now handled. Each records its payload in
  `Game::State` — a per-map teleport-target registry, a single escape target,
  the encounter step rate, and per-slot system music / sound overrides — and
  round-trips through Save / Continue. The Teleport / Escape skills, encounter
  system and battle / menu scenes that would consume these are not built yet, so
  they gate and play nothing at runtime; they are modelled for save fidelity,
  like the teleport / escape access flags. Covered by new checks in
  `scripts/rpg2k_logic_check.rb`.
