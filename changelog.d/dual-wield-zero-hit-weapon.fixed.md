- **Battle:** an RPG2003 dual-wielding actor's swing with a weapon whose
  own hit rate is a genuine 0% (a cursed/joke weapon meant to never land)
  now always misses, matching RPG_RT's `Game_Actor::GetHitChance` -- it
  previously fell back to the 90% unarmed default, the same bug class
  already fixed for the actor's own merged hit rate elsewhere.
