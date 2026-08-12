- **A below/above-characters action event only answers the decision key by
  overlap, never by facing it.** RPG_RT ties the action button to priority
  type the same way it ties collision to it (yado.tk's 決定キーを押しても
  マップイベントが実行しない): a trigger-0 event whose priority type is
  "below characters" or "above characters" — typically one whose graphic is
  an upper-layer chip, which defaults to that priority — only runs when the
  party's own tile overlaps it, never from an adjacent facing tile. Only
  "same as characters" answers the button by facing it (and only by facing
  it, since that priority type blocks the party from ever standing on its
  tile). This build's `try_action_trigger` checked the faced tile — and the
  counter-reach chain beyond it — for any trigger-0 event regardless of
  priority type, so a below/above-characters event could be triggered by
  merely walking up to it, which RPG_RT never allows. Covered by new checks
  in `scripts/rpg2k_scene_check.rb`.
