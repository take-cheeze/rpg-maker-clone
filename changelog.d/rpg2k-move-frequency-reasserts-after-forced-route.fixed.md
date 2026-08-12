- RPG Maker 2000: an event's Move Frequency, as configured on its page, now
  reasserts itself once a forced Move Route (Move Event / Set Move Route)
  finishes, instead of staying at whatever a `Frequency Up`/`Frequency Down`
  sub-command inside that route last left it at. `Scene::Map#step_event`
  only set `move_frequency` from the page when the page was (re)built, so a
  frequency change made mid-route leaked into whatever paced the event
  afterwards. Covered by a new `scripts/rpg2k_scene_check.rb` check.
