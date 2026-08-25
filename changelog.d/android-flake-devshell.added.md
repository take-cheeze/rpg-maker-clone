- **Android:** the build environment moved into the flake, matching the PSP
  toolchain's treatment: `packages.android-sdk` (nixpkgs androidenv, pinned to
  `app/build.gradle`'s own ndkVersion 27.2.12479018, compileSdk 34, build-tools
  34.0.0 and CMake 3.22.1, licenses pre-accepted) and a `nix develop .#android`
  shell exporting `ANDROID_HOME`/`ANDROID_NDK_HOME`/`JAVA_HOME`, so
  `nix develop .#android -c bash -c 'cd app/android && ./gradlew
  :app:assembleDebug'` needs no hand-installed `~/android-sdk`. The manual
  SDK recipe stays in `app/android/README.md` for non-nix builds; CI keeps its
  runner-SDK flow.
