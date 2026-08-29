- **Battle** a battler asleep/paralysed when the round's turn order is built
  no longer regains its turn just because the restriction is cured by
  something else before its own turn comes up — RPG_RT locks "cannot act" in
  once the queue is built (or the instant a restriction lands mid-round), and
  never reverses it, confirmed against a reference implementation's own
  turn-selection and state-adding code, not independently confirmed against
  genuine RPG_RT under wine. See ADR 0052.
