- **Show Choices honours its cancel setting.** The command's first parameter —
  the cancel behaviour, which the interpreter used to ignore — is a 1-based
  option index: 0 forbids cancelling, 1..4 makes the cancel key pick that
  choice, and 5 runs a dedicated **[Cancel] branch**. That branch is stored as a
  *fifth* option (index 4) with an empty label, which the choice window was
  drawing as a blank extra row that shifted the routing of every option after
  it. Only options 0..3 are listed now (ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine), and
  `Scene::Map` backs out of a cancellable choice on the cancel key, playing the
  system cancel sound; a block with cancel type 0 swallows the key as RPG_RT
  does. 336 of Nepheshel's 349 choice blocks are cancellable and 27 carry a
  [Cancel] branch that was previously unreachable.
