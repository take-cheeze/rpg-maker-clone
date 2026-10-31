- Close the `getidx`/`getidx0` index helpers by refreshing the stale Proc-arm
  `vm.c` needle to the fork's current `mrb_funcall_with_method` tail call.
  The lookup-skip property it pins is unchanged; the old 8-argument
  `funcall_with_block_m` tail call no longer exists, so the arm never
  verified and the helpers stayed by-name.
