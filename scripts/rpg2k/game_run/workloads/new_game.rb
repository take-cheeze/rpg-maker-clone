# Headless New Game: start the RPG2k runtime on the project and run frames. run.sh prepends GAME_DIR and RTP_DIR.
g = RPG2k.new(['TestPlay'])
g.start_new_game
puts "new game started"
60.times { g.main_loop }
puts "60 frames ok"
