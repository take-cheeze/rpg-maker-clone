# Zundamon (ずんだもん) message-window narration (ADR 0046) -- the desktop
# build's Scene::Map#speak_message. Builds that can never have a VOICEVOX
# backend (every target but the desktop "host" build, see
# tools/rgss_tts_config.rb) drop this file and ship the empty
# mrblib_limited/map_tts_off.rb in its place, so RGSS::Tts is neither
# registered nor named by any Ruby there (ADR 0417). Loaded after map.rb (sorted
# rbfiles), which defines Scene::Map and calls #speak_message.
class RPG2k
  module Scene
    class Map < Base
      private

      # Read a page's plain, fully-expanded text aloud (variables and actor
      # names already substituted, colour/pacing control codes already
      # stripped -- see `plain` in #open_message/#append_choice_lines) as the
      # page opens. Covers both Show Text and Show Choices -- a standalone
      # choice window reads its options through #open_message(lines, true),
      # and one merged onto a preceding Show Text reads just the appended
      # options through #append_choice_lines, never the text above it again. A
      # no-op whenever --zundamon_tts was not passed or its VOICEVOX assets
      # are not installed (RGSS::Tts.available? is false either way), so this
      # changes nothing about any other run.
      def speak_message(plain_lines)
        return unless RGSS::Tts.available?
        text = plain_lines.join("\n")
        RGSS::Tts.speak(text) unless text.strip.empty?
      end
    end
  end
end
