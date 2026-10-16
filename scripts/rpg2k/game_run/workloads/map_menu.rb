# Headless map and menu: New Game, run the map for 120 frames, push the menu, run 60 more frames.
# run.sh prepends GAME_DIR and RTP_DIR.
g = RPG2k.new(['TestPlay'])
g.start_new_game
120.times { g.main_loop }
map_scene = g.instance_variable_get(:@scenes).last
state = map_scene.instance_variable_get(:@state)
puts "map frames ok: #{map_scene.class}"
g.push RPG2k::Scene::Menu.new(g, state)
puts "menu pushed: #{g.instance_variable_get(:@scenes).last.class}"
60.times { g.main_loop }
puts "menu frames ok: #{g.instance_variable_get(:@scenes).last.class}"
