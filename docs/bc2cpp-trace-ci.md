# bc2cpp trace job

`.github/workflows/bc2cpp-trace.yml` runs on demand and nightly. It is not a pull-request gate.

1. Builds the closed-world `libmruby.a` with `BC2CPP_TRACE_TYPES=1` (`scripts/bc2cpp/closed_build.bash`).
2. Runs Nepheshel New Game on the headless host for 600 frames (`scripts/bc2cpp/trace_host.bash`). The job fails if the
   run writes no `PARAM_`/`RETURN_` rows.
3. Writes `report.txt` (`trace_types.rb report`), `candidates.rbs` (`trace_types.rb candidates`) and `proposals.rbs`
   (`trace_merge.rb`, the candidates the committed declarations do not already name), and uploads them with the raw
   dump and the run log as the `bc2cpp-trace` artifact.

Nothing is written into the repository. A proposal reaches `sig/bc2cpp/declarations.rbs` only through a reviewed pull
request, as with any hand-curated declaration.

Limits: one game, one 600-frame title-to-map run, no input. The trace covers what that run reaches, so a proposal
absent from the run is not evidence the method is unused.
