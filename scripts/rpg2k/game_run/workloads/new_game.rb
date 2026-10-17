# Headless New Game: start the RPG2k runtime on the project and run frames. run.sh prepends GAME_DIR and RTP_DIR.
# Press a key for one frame, then run `frames` frames (the engine clears triggers at the end of each frame).
def tap(g, key, frames = 20)
  RGSS::Input.press(key)
  frames.times { g.main_loop }
end
g = RPG2k.new(['TestPlay'])
g.start_new_game
puts "new game started"
60.times { g.main_loop }
puts "60 frames ok"
