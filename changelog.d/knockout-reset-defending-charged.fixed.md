- **Battle:** a defending or charged enemy that dies now immediately loses
  that stance, matching RPG_RT's own status-application logic (ported from
  a reference implementation, not independently confirmed against genuine
  RPG_RT under wine) -- a revived enemy previously kept its stale
  pre-death Defend/Charge flag until its own next turn, wrongly halving
  incoming damage or
  doubling its next attack in the meantime.
