- **bc2cpp register flow** now models the optional-argument `switch` that
  replaces ENTER's jump table: the default-value targets are successors of
  that switch, so methods with optional parameters are no longer refused for
  its `goto`s. Only the exact generated switch text is trusted; any other
  shape still refuses the method. `BC2CPP_REGISTER_FLOW_GOTO=0` restores the
  old refusal. Covered by `scripts/bc2cpp/register_flow_check.rb`.
