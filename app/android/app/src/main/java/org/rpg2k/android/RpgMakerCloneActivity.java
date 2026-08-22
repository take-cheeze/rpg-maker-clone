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
        return new String[] { "--game_dir", gameDir };
    }
}
