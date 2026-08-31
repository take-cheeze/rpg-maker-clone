- New `scripts/mruby_bare_hash_push_check.rb`: a static, maker-agnostic scan
  across every `mruby-*/mrblib` tree for a bare, unbraced trailing
  keyword-style hash passed into `Array#push`/`#unshift`/`#concat`. Those are
  builtin C-defined methods with no declared keyword parameters, and unlike
  CRuby (which falls back to treating an unbraced trailing hash as one
  ordinary positional `Hash` argument when the callee declares no keyword
  parameters), this project's mruby build does not make that same fallback
  for a builtin method — the hash silently evaporates instead of being
  pushed, with no exception anywhere to catch it. Two real instances shipped
  silently broken this way (`Interpreter#do_move_event`,
  `Interpreter#do_flash_sprite` — see
  `changelog.d/move-event-queue-bare-hash-push.fixed.md`), and neither
  `scripts/rpg2k_scene_check.rb` nor `scripts/rpg2k_logic_check.rb` could
  ever have caught them: both run these same sources unchanged under CRuby,
  which cannot see this class of divergence at all (the same blind spot ADR
  0021 already names two prior examples of). This check instead scans the
  source text itself, so the exact bug shape can never silently reappear —
  in any maker gem, not just RPG2k — regardless of which Ruby eventually
  runs it. Confirmed to fail at the exact two offending lines against the
  pre-fix sources, and to pass cleanly against the fixed ones. Wired as its
  own `build` job step ahead of the existing RPG2k game-logic checks.
