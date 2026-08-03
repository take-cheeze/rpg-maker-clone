# RPG Maker 2000 sample-game analysis

An analysis of the RPG Maker 2000 sample-game collection kept in Google Drive
(folder `1HIcs…`), done to prioritise the clone's remaining work from **real
game content** rather than guesswork. It answers: what data and event commands
do actual RPG2000 games use, and how much of that does the current runtime
already handle?

The analysis is reproducible with the companion tool
[`scripts/analyze_game.rb`](../scripts/analyze_game.rb), which loads the repo's
own pure-Ruby LCF parser (`mruby-lcf`) and walks a game's `RPG_RT.ldb` common
events and `Map*.lmu` event pages.

## Method and data fidelity

* The parser is the project's own `mruby-lcf/mrblib/{lcf,schema}.rb}`, run under
  CRuby (same approach as `scripts/lcf_testbed_check.rb`), so "does this game
  parse?" is answered by the exact code the runtime uses.
* Outbound access to Google Drive is blocked by this environment's egress
  policy, so the binary files were retrieved through the Drive integration,
  which returns file bytes as base64. **Large files (`RPG_RT.ldb`, big maps)
  are delivered exactly**; the databases analysed below were verified
  byte-for-byte against their published sizes (Sample2 `RPG_RT.ldb` = 80 059 B,
  Sample3 = 150 100 B).
* **Caveat:** small files (< ~28 KB) arrive inline and could not be reproduced
  byte-exact, so per-map **event tallies were not reliably captured** in this
  pass. The figures below are therefore **database + common-event** figures,
  which are byte-exact. Common events are where a game's reusable logic lives,
  so this already answers the coverage question; per-map dialogue/movement adds
  volume in commands the runtime mostly already implements (`ShowMessage`,
  `MoveEvent`, `ControlSwitches`). Running `analyze_game.rb` on a locally-cloned
  game completes the map-event picture.

### How commands are classified

The tool sorts every event-command opcode into three buckets, because raw
opcode counts are misleading — developer comments and blank editor lines are the
single largest category in real data and must not be counted as "missing":

| Bucket | Meaning |
| --- | --- |
| **implemented** (`✓`) | The interpreter has a real handler (`mruby-rpg2k/mrblib/interpreter.rb`). |
| **no-op by design** (`·`) | `Comment` (12410/22410) and blank/block-structure lines (codes 0 and 10 — empty, param-less). RPG_RT skips these and so does the interpreter; correctly handled, **not** a feature gap. |
| **feature gap** (`✗`) | Unimplemented and would change behaviour if run. |

## The collection

39 game projects plus two index files:

* **`Sample1`–`Sample7`** — seven official-style RPG2000 projects (the runtime
  `RPG_RT.exe` is byte-identical across every folder).
* **`Extra01`–`Extra32`** — 32 **ツクールコンパク** contest-winning games
  (2000–2002), catalogued in `Games1.txt`/`Games2.txt`.

Every folder is a standard project: `RPG_RT.ldb` (database), `RPG_RT.lmt` (map
tree), `Map####.lmu` (maps + events), `RPG_RT.ini`, `RPG_RT.exe`, and the usual
asset directories (`CharSet`, `ChipSet`, `FaceSet`, `Picture`, `Panorama`,
`Backdrop`, `Battle`, `Monster`, `Music`, `Sound`, `GameOver`, `Title`,
`System`, `Movie`).

File-level metadata gathered for the first three samples:

| Game | `RPG_RT.ldb` | Maps | Notes |
| --- | --- | --- | --- |
| Sample1 | 312 KB | Map0001–0038 | largest DB of the three |
| Sample2 | 80 KB | 88 (Map0001–0088) | many tiny maps; RPG2000 |
| Sample3 | 150 KB | ~36 | a few very large maps (Map0001 460 KB, Map0002 325 KB, Map0008 184 KB) |

### Contest games (`Extra01`–`Extra32`)

ツクールコンパク award winners; medal and award month from the index files.

| # | Title | Author | Awarded | Medal |
| --- | --- | --- | --- | --- |
| 01 | ゲームパッキング | リィ | 2000-09 | Gold |
| 02 | ほいほい | 岩島大悟 | 2000-10 | Silver |
| 03 | ポインタの冒険 | Gaz | 2000-10 | Bronze |
| 04 | On Holy Day. 〜Treasuries〜 | 野口寿一 | 2000-12 | Bronze |
| 05 | B.J to D.J | 野口寿一 | 2001-02 | Bronze |
| 06 | Gu-L | 焼城ユブ | 2001-03 | Silver |
| 07 | Good Viking | リィ | 2001-04 | Gold |
| 08 | 盗人講座 | 中西亘 | 2001-05 | Gold |
| 09 | BELIEVE it or not | Ｃｈｏ−ｙａ | 2001-07 | Gold |
| 10 | PIEACE OF MEMORY | 梅田貴嗣 | 2001-07 | Bronze |
| 11 | ＜業＞ 〜パライソ〜 | 杉夜しん | 2001-07 | Bronze |
| 12 | マテリアル −カルチアの詩− | 708 | 2001-08 | Gold |
| 13 | キマイラ・ブーム | みゃこ | 2001-08 | Bronze+1 |
| 14 | まっは まん２（番煎じ） | 昨日 | 2001-09 | Silver |
| 15 | Soul Of Dandizm | Frontier Field | 2001-09 | Bronze |
| 16 | Ruin of lay | TANI | 2001-11 | Silver |
| 17 | 満月の夜の姫 | 秋里京子 | 2001-11 | Bronze+1 |
| 18 | Education | まうす | 2001-12 | Bronze+1 |
| 19 | 飛べない虫 | スカラベ | 2001-12 | Bronze+1 |
| 20 | 天使の絵本 —THE FABLES ALTER— | さもなー | 2002-01 | Gold |
| 21 | Legend Of Royal —幻の宮殿— | 大山秀一 | 2002-01 | Silver |
| 22 | 旋風仮面 | リィ | 2002-02 | Gold |
| 23 | フラン ニュー エンゼ | 怪盗カイト | 2002-02 | Bronze |
| 24 | ルインハンターライチ | サークルＤｏｏｒ | 2002-03 | Bronze+1 |
| 25 | 今の風を感じて | ヒデ、辺境紳士 | 2002-04 | Gold |
| 26 | 戦伝 〜４ever〜 | Yugon | 2002-06 | Silver+1 |
| 27 | Traveler | 入江ノジコ | 2002-06 | Silver |
| 28 | たのしいもり | ゆわか | 2002-06 | Silver |
| 29 | 早押しボンバー | DRAGONROADS.REAV | 2002-06 | Bronze+1 |
| 30 | 水護墓 | 茶林小一 | 2002-06 | Bronze |
| 31 | Bombe | Hiroki | 2002-06 | Bronze |
| 32 | Fire! | コウ | 2002-06 | Bronze |

## Per-game deep dive

### Sample2 — a compact battle/cutscene demo

Database: **8 actors, 65 skills, 110 items, 50 enemies, 58 troops**, 3 chipsets,
39 animations, 321 switches, 40 variables. The large monster/skill/troop tables
mark this as the battle-showcase sample.

Common-event commands (161 total):

* **correctly handled: 80.7 %** = implemented 65.8 % + no-op-by-design 14.9 %
* **genuine feature gaps: 19.3 %** across 10 opcodes

| Opcode | Count | Status |
| --- | --- | --- |
| ShowMessage (+cont.) | 44 | ✓ |
| ControlSwitches | 11 | ✓ |
| Wait | 11 | ✓ |
| ConditionalBranch / Else / EndBranch | 25 | ✓ |
| PlaySound / PlayBGM | 10 | ✓ |
| ControlVars / ChangeGold | 5 | ✓ |
| **ShowPicture / ErasePicture** | 10 | ✗ pictures |
| FlashScreen / TintScreen | 8 | ◐ Tint + Flash state machines done (tone/alpha render pending) |
| **MessageOptions** | 4 | ✗ message window setup |
| **ChangeFaceGraphic** | 4 | ✗ message face |
| MemorizeBGM / PlayMemorizedBGM | 2 | ✓ BGM stack |
| **EnemyEncounter** | 1 | ✗ battle |
| unknown(10660) | 2 | ✗ unidentified 106xx opcode |

Sample2's gaps are **presentational**: pictures, screen flash/tint, message
face graphics, and battle entry — i.e. the cutscene and combat surface.

### Sample3 — a scripting-heavy adventure

Database: 12 actors, 8 skills, 114 items, **1 enemy, 1 troop** (combat is
incidental), 8 chipsets, 82 animations, and **5000 switches / 5000 variables —
both maxed out**, the signature of heavy event scripting.

Common-event commands (1919 total):

* **correctly handled: 99.5 %** = implemented 53.9 % + no-op-by-design 45.5 %
* **genuine feature gaps: 0.5 %** (10 commands across 7 opcodes)

| Opcode | Count | Status |
| --- | --- | --- |
| Comment (+cont.) | 706 | · developer annotation |
| ControlVars | 428 | ✓ |
| ConditionalBranch / EndBranch | 326 | ✓ |
| BlankLine (codes 10, 0) | 168 | · structural no-op |
| ControlSwitches | 133 | ✓ |
| JumpToLabel / Label | 114 | ✓ |
| CallEvent | 30 | ✓ |
| MoveEvent / Teleport / ShowMessage | 4 | ✓ |
| MessageOptions, ProceedWithMovement, PanScreen, PlayerVisibility, MemorizeLocation, ChangeMainMenuAccess, unknown(10690) | 10 | ✗ |

Sample3's common events are effectively a **switch/variable state machine**
(`ControlVars` alone is 22 % of all commands) — precisely the subset the
interpreter already implements. Once comments and blank lines are set aside, the
runtime can execute virtually all of it.

## Cross-cutting findings

1. **Comments and blank lines dominate raw counts** (45 % of Sample3's commands,
   15 % of Sample2's). Any coverage metric that ignores this over-reports the
   work left to do. The clone already handles them correctly (as no-ops).
2. **The control-flow / variable / switch core is done and heavily used.**
   `ControlVars`, `ControlSwitches`, `ConditionalBranch`, `Label`/`JumpToLabel`,
   `Loop`, `CallEvent`, `ShowMessage`, `Wait` cover the overwhelming majority of
   real logic. A logic-driven game like Sample3 is ~99 % runnable today.
3. **The remaining gaps are presentation, not logic.** The commands that
   actually appear and are unimplemented cluster into a few themes:

   | Theme | Opcodes seen | Appears in |
   | --- | --- | --- |
   | **Pictures** | ShowPicture (11110), MovePicture (11120), ErasePicture (11130) | Sample2 |
   | **Screen effects** ◐ | ShakeScreen (11050) + PanScreen (11060) implemented and visible (camera offset/lock); TintScreen (11030) + FlashScreen (11040) state machines done (viewport tone/alpha render pending) | Sample2, Sample3 |
   | **Message polish** ✅ | MessageOptions (10120), ChangeFaceGraphic (10130) — now implemented | Sample2, Sample3 |
   | **Battle** | EnemyEncounter (10710) | Sample2 |
   | **BGM stack** ✅ | MemorizeBGM (11530), PlayMemorizedBGM (11540) — now implemented | Sample2 |
   | **Movement sync** ✅ | ProceedWithMovement (11340) — now implemented | Sample3 |
   | **Menu/telep. access, misc** ✅ | ChangeMainMenuAccess (11960) and MemorizeLocation (10820) now implemented; PlayerVisibility (11310) remains | Sample3 |
   | **Unidentified** | code 10660, 10690 (106xx range) | Sample2, Sample3 |

## Recommended priorities for the interpreter

Ordered by real-world frequency across the analysed games:

1. ✅ **`MessageOptions` (10120)** and **`ChangeFaceGraphic` (10130)** —
   *implemented.* The interpreter records the window setup (transparency,
   top/middle/bottom position, continue-events) and the FaceSet selection on a
   saved `Game::MessageConfig`, and `Scene::Map` positions the window, draws it
   transparent and blits the face beside the text. Covered by
   `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
2. **Pictures — `ShowPicture`/`MovePicture`/`ErasePicture` (11110/11120/11130)**
   — the biggest single gap in Sample2 and pervasive in RPG2000 cutscenes and
   custom menus.
3. **Screen effects — `TintScreen`/`FlashScreen`/`PanScreen` (11030/11040/11060)**
   — common cutscene polish, appear in both games. ◐ `ShakeScreen` (camera
   shake) and `PanScreen` (lock / pan / reset a camera offset) are implemented
   and **visible** through the existing camera; `TintScreen` + `FlashScreen` are
   host-tested `Game::Screen` state machines (interpolation/fade + the shared
   wait flag) whose only remaining half is drawing them through an
   `RGSS::Viewport` tone/alpha in C++. The whole screen-effects family now lives
   on `Game::Screen`.
4. **`EnemyEncounter` (10710)** — the entry point to the (still-unbuilt) battle
   system; unblocks the battle-showcase samples.
5. ✅ **`ProceedWithMovement` (11340)** — *implemented.* Pairs with the existing
   Move Event support so a forced route can be awaited: the interpreter pauses
   until every forced route in progress finishes. Covered by
   `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
6. Lower priority: ✅ BGM memorize/replay (`MemorizeBGM`/`PlayMemorizedBGM`,
   *implemented* — stash the current BGM and restore it, minus seek-to-position),
   ✅ `MemorizeLocation`/`RecallToLocation`
   (*implemented* — store the player position into three variables and teleport
   back to it; covered by `scripts/rpg2k_logic_check.rb` and
   `scripts/rpg2k_scene_check.rb`), ✅ `ChangeMainMenuAccess` (11960) and
   `ChangeSaveAccess` (11930) (*implemented* — gate opening the menu and saving;
   covered by the same two harnesses), the teleport/escape access toggles,
   `PlayerVisibility`.
7. **Identify opcodes 10660 and 10690** — unnamed in the current opcode table;
   worth confirming against liblcf before implementing.

## Recommended test-beds

* **Sample3** — best **event-interpreter** regression target: pure switch/
  variable/branch/call logic, ~99 % already runnable, minimal art/battle
  dependencies. Good for `scripts/rpg2k_logic_check.rb`-style coverage.
* **Sample2** — best **feature-driver**: small, but exercises pictures, screen
  effects, faces, and battle entry — a compact checklist for the presentation
  gaps above.
* The **contest games (`Extra*`)** are the most valuable stress test of parser
  robustness and command coverage against non-official authoring styles; run
  `analyze_game.rb` over them once their data is available locally.

## Reproducing / extending

```sh
# one game
ruby scripts/analyze_game.rb path/to/game_dir
# machine-readable
ruby scripts/analyze_game.rb --json path/to/game_dir
# many games, or auto-discover under ./data
ruby scripts/analyze_game.rb data/*/
```

The tool reports database entity counts, the classified event-command histogram
(implemented / no-op / gap), move-route command usage, and — when run on a game
whose `Map*.lmu` files are present locally — per-page trigger and move-type
breakdowns. The `SUPPORTED` and `NOOP_BY_DESIGN` sets in the script mirror the
interpreter, so re-running after implementing a command immediately reflects the
improved coverage.
