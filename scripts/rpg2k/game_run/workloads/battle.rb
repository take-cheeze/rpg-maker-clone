# Headless battle: New Game, push a battle against troop 1 with an owner stub that accepts the result, run frames.
# Press a key for one frame, then run `frames` frames (the engine clears triggers at the end of each frame).
def tap(g, key, frames = 20)
  RGSS::Input.press(key)
  frames.times { g.main_loop }
end
class BattleOwnerStub
  attr_reader :result
  def resume_battle(result); @result = result; end
end
g = RPG2k.new(['TestPlay'])
g.start_new_game
60.times { g.main_loop }
map_scene = g.instance_variable_get(:@scenes).last
req = Game::Interpreter::BattleRequest.new
req.troop_id = 1
req.allow_escape = true
owner = BattleOwnerStub.new
g.push RPG2k::Scene::Battle.new(map_scene, req, owner)
600.times { g.main_loop }
puts "battle frames ok: #{g.instance_variable_get(:@scenes).last.class} result=#{owner.result.inspect}"
