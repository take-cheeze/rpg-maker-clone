# Issue and pull-request labels

Labels answer three questions about a report before anybody opens it: **which
RPG Maker edition**, **which target**, and **which part of the engine**. Plus
what kind of work it is, and why it is not moving.

The definitions live in [`.github/labels.yml`](../.github/labels.yml) — that
file is the source of truth, and editing it on `master` re-applies the labels
to GitHub (see [Syncing](#syncing) below).

## Groups

| Group | Meaning | Values |
| --- | --- | --- |
| `engine:` | The RPG Maker edition whose games or runtime behaviour is at stake | `rpg2k`, `rpg2k3`, `xp`, `vx`, `vxace`, `mv`, `mz` |
| `platform:` | The build target it is specific to | `wasm`, `terminal`, `linux`, `windows`, `psp`, `wio`, `other` |
| `component:` | The part of the engine it lives in | `graphics`, `audio`, `input`, `runtime-mruby`, `runtime-js`, `data`, `save`, `events`, `scenes`, `battle`, `build`, `ci`, `docs`, `tooling` |
| `type:` | The kind of work | `bug`, `feature`, `parity`, `refactor`, `chore`, `question` |
| `status:` | Why it is not moving | `blocked`, `needs-info` |

An issue normally carries one `type:` plus whichever engine / platform /
component labels apply. Several of each is normal and correct — a tilemap
priority fix is `engine:xp` + `engine:vx` + `component:graphics`, because one
code path serves both editions.

Some choices worth knowing:

- **`engine:` follows the game data, not the code.** An LCF schema change that
  only matters for 2003 data is `engine:rpg2k3` even though it lands in
  `mruby-lcf`, which 2000 shares.
- **`engine:vx` and `engine:vxace` travel together** by default: one data layer
  serves RGSS2 and RGSS3 (ADR 0024). Drop one when a change really is
  Ace-only.
- **Leave `platform:` off** unless the problem is target specific. Most changes
  are not.
- **`type:parity` is the repo's own axis**: the behaviour is implemented, it
  just does not match RPG_RT / the corescript yet. The wine comparison
  harnesses (`scripts/compare-*-wine.bash`) produce these.
- **`component:runtime-mruby` is the mruby VM and its gems** (`build_config.rb`,
  `mrbgem.rake`, mruby/CRuby divergence). Ruby code that implements a *game*
  belongs to whatever it implements — `component:events`, `component:scenes`, …
- **`component:runtime-js` is the QuickJS host** for MV/MZ: the bindings,
  canvas and WebGL under `mruby-mvjs/src`. The corescript-facing Ruby
  (`mv.rb`, `mz.rb`) is `engine:mv` / `engine:mz` work.

## How labels get applied

**Pull requests** are labelled from their changed paths by
[`actions/labeler`](../.github/workflows/labeler.yml), using the rules in
[`.github/labeler.yml`](../.github/labeler.yml). The rules only cover paths
whose engine / platform / component is unambiguous; the big mixed files
(`mruby-rpg2k/mrblib/game.rb` holds the chipset, the message window, the battle
*and* the weather) get none, so add those by hand. Labelling never removes
anything (`sync-labels: false`), so a hand-added label survives the next push.

Because the workflow runs on `pull_request_target` — so pull requests from
forks can be labelled at all — the rules are read from `master`. A change to
`.github/labeler.yml` therefore only takes effect once it is merged.

**Issues** opened through a form
([`.github/ISSUE_TEMPLATE`](../.github/ISSUE_TEMPLATE)) carry their `type:`
label from the form itself, and their Engine / Platform / Component pickers are
mapped to labels by
[`scripts/issue_form_labels.rb`](../scripts/issue_form_labels.rb), run by
[`.github/workflows/issue-labels.yml`](../.github/workflows/issue-labels.yml)
on open and on edit. Blank issues stay enabled; they just arrive unlabelled.

Everything the two automations can apply is checked against the definitions by
`scripts/label_config_check.rb`, which runs from pre-commit (and so in CI):

```bash
ruby scripts/label_config_check.rb
```

It fails on a label that no longer exists, an issue-form option nobody mapped,
a dropdown option containing a comma (the answer line is comma separated and
could not be split), a bad colour, and a labeler rule with no globs. It also
runs a handful of cases through the issue-body parser.

## Syncing

`.github/labels.yml` is applied to GitHub by
[`scripts/sync_github_labels.rb`](../scripts/sync_github_labels.rb), which
[`.github/workflows/labels.yml`](../.github/workflows/labels.yml) runs on every
push to `master` that touches it. To try it locally against the real
repository:

```bash
gh auth status                                     # needs an authenticated gh
ruby scripts/sync_github_labels.rb --dry-run       # print what would change
ruby scripts/sync_github_labels.rb                 # create / update
```

Creating and updating are idempotent. **Deleting is opt-in**: a label that is
not in the file is left alone unless the sync is run with `--prune` (or the
manual *Labels* workflow run is started with the `prune` box ticked), so a
label added by hand in the issue tracker is not swept away by the next edit.

## Adding a label

1. Add it to `.github/labels.yml` — group prefix, six-digit colour matching the
   rest of its group, and a description that says when to use it.
2. If it can be inferred from changed paths, add a rule to
   `.github/labeler.yml`.
3. If a reporter should be able to pick it, add the option to the issue forms
   and map it in `scripts/issue_form_labels.rb`.
4. `ruby scripts/label_config_check.rb`, then open the pull request. The label
   appears on GitHub when it merges.
