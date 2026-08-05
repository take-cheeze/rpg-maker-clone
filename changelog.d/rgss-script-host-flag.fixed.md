- The **RGSS script host can actually be turned on**. Every document named
  `RGSS_SCRIPT_HOST=1` as the opt-in, and it could never have worked: this mruby
  build has no `ENV` (no `mruby-env` gem is vendored or configured), so
  `ScriptHost.enabled?` returned false in every built engine, on every target,
  and the host never ran. Only the CRuby harnesses — where `ENV` does exist —
  ever exercised the switch, which is why the dead opt-in went unnoticed. The new
  `--rgss_script_host` flag is published to the Ruby side as a constant, the way
  `--rpgxp_new_game` already is; the environment variable is still honoured for
  the harnesses.
- A script-host boot failure now names the **section** that raised
  (`section "Sprite_Character" raised NameError: ...`) instead of only the
  exception, so a failure reads as a report about which part of the RGSS class
  library is missing. Re-raised explicitly, because a bare `raise` in a rescue
  loses the exception in this mruby build — the caller had been reporting an
  empty `RuntimeError`.
