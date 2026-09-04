- `docs/TODO.md`'s VX/VX Ace "A real test bed" entry still said finding a
  redistributable bed for CI "remains open," written before
  `scripts/download-monodori.bash` and `scripts/download-sanctuary-of-the-ruler.bash`
  landed. Updated to reflect the current state: VX now has a real, fetchable,
  CI-wired bed (Monochrome Dreamer / monodori); VX Ace has a real one too
  (Sanctuary Of the Ruler), just kept out of CI for exceeding the repo's 100MB
  per-test-bed budget, the same call already made for `download-egoicanswers.bash`
  on the MZ side. Doc-only, no code change.
