- The RPG2000 runtime now models **actor equipment**: five slots (weapon, shield,
  armour, helmet, accessory) whose item bonuses fold into the six effective stats
  on top of the level-scaled base. New Game equips an actor's initial gear,
  Continue re-equips the saved gear (chunk 108 field 61), `Game::Actor#atk`/etc.
  and the Change Variable actor-stat operand see the boosted values, and the
  "actor has item equipped" conditional branch (type 5, sub 5) is modelled. Also
  adds `LCF::Array1D#respond_to_missing?` so `respond_to?` reflects schema field
  names. Verified on Nepheshel (hero's dagger +28 atk, cloth armour +7 def) and
  covered by the logic and save-load checks. See ADR 0016.
