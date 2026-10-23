- The Android build no longer vendors SDL2 and SDL2_mixer as submodules
  (`3rd/SDL`, `3rd/SDL_mixer`). CMake and Gradle download the pinned SDL 2.32.10
  and SDL2_mixer 2.8.2 release tarballs at build time and check their sha256.
  Desktop, Emscripten and the other ports keep using their existing SDL source.
