- **Battle:** a defending or charged enemy that dies now immediately loses
  that stance, matching RPG_RT's `Game_Battler::AddState` Knockout branch
  -- a revived enemy previously kept its stale pre-death Defend/Charge
  flag until its own next turn, wrongly halving incoming damage or
  doubling its next attack in the meantime.
