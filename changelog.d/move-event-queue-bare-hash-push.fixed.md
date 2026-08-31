- **A Move Event (Set Move Route) command silently did nothing on this
  build's mruby, while working fine under the CRuby test harnesses — found
  investigating Nepheshel map 23 event 29 ("HiddenDoor"), a flagless secret
  passage that uses its own facing as covert state (see the event's own
  comment, フラグを使用しない隠し扉): pressing the action key facing the
  sealed wall played its SE (confirming the interpreter reached and
  evaluated its script correctly) but the door never slid aside or turned to
  face right.** `Interpreter#do_move_event` queued the request with
  `@move_route_requests.push(target: ..., frequency: ..., repeat: ...,
  skippable: ..., commands: ...)` — a bare, unbraced trailing keyword-style
  hash. `Array#push` is a builtin C-defined method with no declared keyword
  parameters, and unlike CRuby (which falls back to treating an unbraced
  trailing hash as one ordinary positional `Hash` argument when the callee
  declares no keyword parameters), this project's mruby build does not make
  that same fallback for a builtin method — the hash silently evaporated
  instead of being pushed, with no exception and no `[RPG2k]`-tagged
  diagnostic, since `Interpreter#update`'s per-command dispatch has nothing
  to catch. `Scene::Map#apply_move_requests` then found the queue empty and
  had nothing to apply: no `force_event_route` call, so the door's own
  `Game::MoveRoute` (`Through On → Move Down → Face Right`) never ran, and
  `Proceed With Movement`'s wait resolved immediately (`forced_movement_done?`
  is trivially true when no event has a `forced_route` armed at all) —
  matching the exact symptom of "SE plays, nothing else happens."
  Confirmed directly: adding temporary debug logging around the
  push/drain pair in a real build showed the same array `object_id` on both
  sides of the call with its size and contents unchanged by the intervening
  `push`, ruling out an aliasing or a different-object explanation.
  `Interpreter#do_flash_sprite`'s identical `@sprite_flash_requests.push(target:
  ..., ...)` call had the same bare-hash shape and the same bug (Flash Sprite
  should have been queuing a request the exact same silently-dropped way);
  Three sibling `@location_requests.push({ ... })` call sites
  (`Interpreter#do_set_vehicle_location`/`#do_change_event_location`/
  `#do_trade_event_locations`) already used an explicit `{ ... }` brace, so
  only `#do_move_event`'s and `#do_flash_sprite`'s had the bare form.
  Fixed by bracing both hash literals
  explicitly (`.push({ ... })`), which is unambiguous — always one ordinary
  positional `Hash` argument — under every Ruby implementation. A full repo
  grep for the same shape (`.push(` followed by a bare `key:` on the next
  line) across `mruby-rpg2k`/`mruby-lcf` found no further instances.
  `scripts/rpg2k_scene_check.rb` (964 checks) and `scripts/rpg2k_logic_check.rb`
  (1188 checks) both still pass under CRuby unchanged, as expected — this is
  a CRuby/mruby divergence CRuby-hosted checks structurally cannot see (see
  `docs/adr/0021-nepheshel-render-parity-under-wine.md`'s own two prior
  examples of this class of gap); confirming this fix in the actual native
  build is the next step.
