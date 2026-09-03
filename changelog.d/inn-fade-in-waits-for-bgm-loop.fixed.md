- **An inn stay now holds the screen black until the inn's own BGM has
  played through once**, instead of starting the fade back in the instant
  the fade-out alone lands — so a long inn track gets to finish playing
  before the party sees the room again, using the same `bgm_looped` ("BGM
  played once") signal Conditional Branch type 9 already reads. A backend
  that cannot report a BGM position skips the wait rather than holding the
  screen black forever. `Scene::Map#start_inn_fade_out`/`#drive_inn`
  (`mruby-rpg2k/mrblib/scene/map.rb`).
