# Scene::Map#speak_message for builds that can never have a Zundamon/VOICEVOX
# backend: wio, maix, psp, emscripten, android. It takes the place
# of mrblib/scene/map_tts.rb (mruby-rpg2k/mrbgem.rake swaps the two), so those
# builds carry no RGSS::Tts native registration and no Ruby naming it. Not
# under mrblib/, so nothing that globs mrblib/**/*.rb sees both definitions.
class RPG2k
  module Scene
    class Map < Base
      private

      def speak_message(plain_lines)
      end
    end
  end
end
