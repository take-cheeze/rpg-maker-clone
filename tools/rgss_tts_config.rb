# frozen_string_literal: true

# Which builds can ever have a RGSS::Tts backend.
#
# The only backend is src/voicevox_tts.cxx: VOICEVOX CORE dlopen()'d on a
# Linux/macOS desktop executable that already links SDL_mixer (the root
# CMakeLists.txt executable for a native build). That executable links the
# mruby "host" build. Every other build -- wio, maix, psp, emscripten, android --
# has no such executable (the cross builds link their own libmruby, not
# src/voicevox_tts.cxx), so RGSS::Tts could only ever be a no-op there.
#
# "host" is also the build `rake test` (mrbtest) runs and the bootstrap
# mrbc-only build inside a cross build; both keep RGSS::Tts, the first so the
# native tests (mruby-rgss/test/native_direct.rb) still cover it.
module RgssTtsConfig
  # The mruby Rakefile build names with a possible backend.
  BACKEND_BUILDS = %w[host].freeze

  # Source swapped for the limited builds (repo-relative).
  RPG2K_TTS_RB = 'mruby-rpg2k/mrblib/scene/map_tts.rb'
  RPG2K_TTS_OFF_RB = 'mruby-rpg2k/mrblib_limited/map_tts_off.rb'
  # mruby-rgss compiles tts.cxx for the builds with a backend, tts_off.cxx for the others.
  RGSS_TTS_CXX = 'mruby-rgss/src/tts.cxx'
  RGSS_TTS_OFF_CXX = 'mruby-rgss/src/tts_off.cxx'

  def self.backend_possible?(build_name)
    BACKEND_BUILDS.include?(build_name.to_s)
  end
end
