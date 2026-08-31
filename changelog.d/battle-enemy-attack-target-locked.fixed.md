- **An enemy's plain basic Attack now locks its target when the round's turn
  order is built, instead of re-rolling it live the instant the attack
  executes.** Previously (`Game::Battle#attack_target`) an enemy always
  picked a fresh random living party member at the exact moment its swing
  landed, so a mid-round party wipe/swap could never make the attack
  "fizzle" the way a real RPG_RT round does — it just silently retargeted
  whoever was still standing. `#refill_queue` now rolls and locks a
  `queued_target` for every enemy in the round's queue, and `#attack_target`
  reads that lock back instead of re-rolling — fizzling with no swing at all
  if the locked target has since fallen or left, the same rule an ally's own
  locked Skill/Item target already gets. A forced attack-ally/attack-enemy
  restriction (berserk/confusion) is unaffected, since it rolls its own
  target independently.
