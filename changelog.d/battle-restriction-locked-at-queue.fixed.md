- **Battle** a battler asleep/paralysed when the round's turn order is built
  no longer regains its turn just because the restriction is cured by
  something else before its own turn comes up — RPG_RT locks "cannot act" in
  once the queue is built (or the instant a restriction lands mid-round), and
  never reverses it, confirmed against EasyRPG's `SelectNextActor`/
  `PrepareBattleAction`/`Game_Battler::AddState`. See ADR 0052.
