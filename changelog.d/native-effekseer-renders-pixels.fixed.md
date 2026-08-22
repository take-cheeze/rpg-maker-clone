- The native Effekseer particle pipeline (`MV::Effekseer.smoke_test`,
  `mruby-mvjs/src/mvefk.cxx`) now confirmed renders real, visible pixels, not
  just a simulated-with-no-error effect: an explicit `Manager::Flip()` call
  before drawing (needed because `Manager::Update`'s autoFlip syncs the
  render-visible snapshot from the *previous* frame, one step stale for a
  one-shot simulate-then-draw call) plus switching the test fixture to
  `Flash.efkefc` (whose particles live on real `Sprite`/`Ring` render nodes)
  now produce real GPU draw calls and hundreds of changed pixels. The
  earlier "zero draw calls" symptom traced to a different fixture
  (`HitPhysical.efkefc`) whose only particles live on a `NoneType` node that
  Effekseer's own renderer never draws by design -- not a pipeline bug.
