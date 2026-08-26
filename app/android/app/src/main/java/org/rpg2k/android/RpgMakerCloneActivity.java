package org.rpg2k.android;

import org.libsdl.app.SDLActivity;

/**
 * Thin SDLActivity subclass: names the two native libraries this build
 * actually produces (root CMakeLists.txt's ANDROID branch, plus the
 * SDL2/SDL2_mixer .so's it builds alongside it -- see
 * docs/adr/0058-android-port.md) and points --game_dir at this app's own
 * external-files directory, the Android equivalent of app/psp's fixed
 * ms0:/PSP/GAME/rpg2k Memory Stick path: `adb push` an RPG Maker project's
 * files there and it is what boots.
 */
public class RpgMakerCloneActivity extends SDLActivity {
    @Override
    protected String[] getLibraries() {
        return new String[] {
            "SDL2",
            "SDL2_mixer",
            "rpg_maker_clone"
        };
    }

    @Override
    protected String[] getArguments() {
        String gameDir = getExternalFilesDir(null) + "/game";
        java.util.ArrayList<String> args = new java.util.ArrayList<>();
        args.add("--game_dir");
        args.add(gameDir);
        // CI hook: `adb shell am start ... --es rpg2k_extra_args "..."` lets
        // the android-smoke CI job (.github/workflows/build.yml) pass the
        // same self-driving flags scripts/rpg2k_boot_check.bash uses on
        // desktop (--test_play --rpg2k_new_game --timeout_ms=..., see
        // src/main.cxx) without any touch-input automation. Absent from every
        // real launch, so getStringExtra returns null and ordinary installs
        // are unaffected.
        String extraArgs = getIntent() != null
            ? getIntent().getStringExtra("rpg2k_extra_args") : null;
        if (extraArgs != null && !extraArgs.trim().isEmpty()) {
            for (String arg : extraArgs.trim().split("\\s+")) {
                args.add(arg);
            }
        }
        return args.toArray(new String[0]);
    }
}
