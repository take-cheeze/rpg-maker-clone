# Headless save and load: New Game, run the map for 60 frames, save slot 1, check the save exists, load it
# back and compare the map. run.sh prepends GAME_DIR and RTP_DIR. The save is written into GAME_DIR, so point
# run.sh at a copy of the project, not the original.
g = RPG2k.new(['TestPlay'])
g.start_new_game
60.times { g.main_loop }
state = g.instance_variable_get(:@scenes).last.instance_variable_get(:@state)
map_before = state.map_id
puts "save written: #{g.save_game(state, 1)}"
puts "save exists: #{g.save_exists?(1)}"
loaded = g.load_save_state(1)
puts "loaded: #{!loaded.nil?} map=#{loaded && loaded.map_id} (was #{map_before})"
