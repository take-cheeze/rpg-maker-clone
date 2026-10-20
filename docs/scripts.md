# Repository scripts

Related scripts live in directories named after their former filename prefix.
The redundant prefix is removed: `bc2cpp_array_push_fastpath_check.rb`
now lives at `scripts/bc2cpp/array_push_fastpath_check.rb`.

| Directory | Purpose |
| --- | --- |
| `bc2cpp/` | Compiler checks, shared test helpers, analysis and reports |
| `rpg2k/`, `rpg2k3/`, `rpgxp/`, `rpgvx/`, `mv/`, `mz/`, `wolf/` | Engine checks and utilities |
| `lcf/`, `rgss/`, `rgssad/` | Data codecs and Ruby compatibility checks |
| `download/`, `rtp/` | Sample projects, assets and RTP installers |
| `build/`, `native/`, `mruby/`, `nix/` | Build and dependency utilities |
| `optcarrot/` | Optcarrot benchmark and dispatch checks |
| `ci/`, `coverage/` | CI helpers and host Ruby coverage |
| `gen/`, `compare/`, `run/` | Generators and Wine comparison/run helpers |

Standalone utilities remain directly under `scripts/`. Shared fixtures remain
in `scripts/fixtures/`; the CORS proxy remains in `scripts/cors-proxy/`.

Run scripts from the repository root unless their usage says otherwise:

```bash
ruby scripts/rpg2k/logic_check.rb
ruby scripts/bc2cpp/array_push_fastpath_check.rb
ruby scripts/coverage/report.rb
bash scripts/download/nepheshel.bash
ruby scripts/build/changelog.rb preview
```

The old flat paths are replaced, so update local aliases and automation to use
these paths. Historical release entries in `CHANGELOG.md` and existing
changelog fragments retain their original command names.

Place new related scripts in the existing group and avoid repeating its name
in the filename. Scripts that locate repository files relative to their own
location must climb two levels from a group directory. Use recursive globs
such as `scripts/**/*_check.rb` when discovering checks.
