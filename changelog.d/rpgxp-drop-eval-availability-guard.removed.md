- Dropped `RPGXP::ScriptHost.available?` and the two `return false unless
  available?` guards it fed. It answered "can this runtime eval Ruby source at
  all", a question that stopped having a second answer when `mruby-eval` became
  a hard dependency of `mruby-rpgxp` (its `mrbgem.rake`) — every build that can
  load `script_host.rb` has `Kernel#eval`, and so does CRuby, which is the only
  other place these sources run. The build invariant it stood for is now asserted
  where it belongs, beside the `mruby-fiber` / `mruby-exit` checks in
  `mruby-rpgxp/test`, so a gem-set regression fails the tests instead of
  silently turning the script host off.
