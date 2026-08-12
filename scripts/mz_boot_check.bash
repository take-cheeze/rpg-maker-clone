#!/usr/bin/env bash

# Boot the built engine on the RPG Maker MZ test-bed (data/mz-sample) and drive
# it into actual play: the rmmz corescript on PIXI v5 renders through the native
# surfaceless-EGL GLES2 backend, `Scene_Boot` finishes loading and hands over to
# `Scene_Title`, `--mz_new_game` picks New Game, and the requested probe then
# exercises one in-game path and reports what happened.
#
# The engine is fetched by scripts/download-mz-corescript.bash; the authored
# database and art (data/mz-sample/data, data/mz-sample/img — see
# scripts/gen-mz-sample.py) are committed. MZ#start (mruby-mvjs/mrblib/mz.rb)
# drives all of this on launch and prints:
#
#   [MZ-BOOT] booted to <scene> through the WebGL renderer
#   [MZ-SCENE] <scene>            (once per scene change)
#   [MZ-MAP]   reached the map at <x,y>
#   [MZ-MOVE]  start <x,y> / end <x,y> moved=<bool>
#   [MZ-AUDIO] op=<se_play> asset=<audio/se/Beep>
#   [MZ-MSG]   busy=<bool> window_open=<bool>
#   [MZ-EQUIP] atk_before=<n> atk_after=<n> weapon=<id> equipped=<bool>
#              stronger=<bool> returned=<bool>
#   [MZ-MSGPLAY] opened=<bool> closed=<bool> choice_shown=<bool> branch=<n>
#              picked=<bool>
#   [MZ-SHOP]  gold_before=<n> gold_after=<n> items_before=<n> items_after=<n>
#              bought=<bool> returned=<bool> scene=<scene>
#   [MZ-ENC]   encountered=<bool> troop=<id> map=<id> scene=<scene>
#   [MZ-COMMON] parallel=<bool> called=<bool> last=[<state>]
#   [MZ-XFER]  from=[<state>] to=[<state>] moved=<bool> landed=<bool>
#              arrived=<bool> scene=<scene>
#   [MZ-MENU]  reached_menu=<bool>
#   [MZ-MENUPLAY] hp_before=<n> hp_after=<n> items_before=<n> items_after=<n>
#              healed=<bool> used=<bool> returned=<bool> scene=<scene>
#   [MZ-ANIM]  data=<bool> mv=<bool> sprites=<n> cells=<n> played=<bool>
#   [MZ-SAVE]  saved=<bool> exists=<bool> loaded=<bool> restored=<bool>
#              [before=<state> after=<state>, when they differ]
#   [MZ-BTL]   reached_battle=<bool>
#   [MZ-BTLPLAY] hp_before=<n> hp_after=<n> alive=<n> damaged=<bool>
#              ended=<bool> scene=<scene>
#
# or "[MZ] boot stopped at: <error>" when it stops short. Every mode asserts the
# boot marker and that the boot got past the loading scene; each then asserts
# its own probe's success line, since a probe that merely *ran* proves nothing.
#
# The mode is picked with MZ_MODE (default `play`):
#
#   play      New Game -> map, hold a direction, play an SE  (the default smoke)
#   message   New Game -> map, show a message
#   transfer  New Game -> map, Transfer Player to the bed's second map
#   common    New Game -> map, run a parallel and a called common event
#   encounter New Game -> map 2, walk until a random encounter fights
#   shop      New Game -> map, open a shop and buy an item in it
#   message_play ... and then *operate* it: page it through, take a choice
#   equip     New Game -> map -> menu -> Equip, put the bed's weapon on
#   menu      New Game -> map, open the party menu
#   menu_play    ... and then *use that menu*: heal with an item, back out
#   animation New Game -> map, play an animation on the player
#   save      New Game -> map, save + load round-trip, state verified back
#   battle    New Game -> map, start a battle against MZ_TROOP (default 1)
#   battle_play  ... and then *play that battle out* to its end
#
# The MZ engine mirror is a CI-only fixture (© Gotcha Gotcha Games / KADOKAWA);
# if it has not been fetched the check skips with a message rather than failing,
# the same way the RPG2k/XP boot checks skip an absent downloaded game.
#
# Usage: MZ_MODE=<mode> ./scripts/mz_boot_check.bash [server_num] [game_dir]

set -eu -o pipefail

cd "$(dirname "$0")/.."

SERVER_NUM="${1:-111}"
GAME="${2:-data/mz-sample}"
ENGINE="${ENGINE:-./build/rpg_maker_clone}"
MODE="${MZ_MODE:-play}"
TROOP="${MZ_TROOP:-1}"
# The run has to reach the title, start a New Game, load the map and then play
# out its probe, all on software GL — so it is given far more in-game time than
# the MV smokes, which only need to boot.
#
# This is a ceiling, not a running time: the engine now ends the run as soon as
# every requested probe has reported (MZ#finish_when_probes_done), so a mode
# that finishes in ten seconds takes ten seconds whatever this says. It only has
# to be generous enough for the *slowest* host, because the two budgets are in
# different units — a probe gives up after so many frames, this after so many
# milliseconds, and a headless software-GL frame costs far more wall clock on a
# loaded machine. Set too tight, a run is cut off mid-probe and reports nothing,
# which reads downstream as the thing under test never happening (see the
# `cut off` diagnostics below). The play-out modes drive several turns / a whole
# window stack, so they get the most room.
DEFAULT_TIMEOUT_MS=60000

case "${MODE}" in
    play)
        FLAGS=(--mz_new_game --mz_move_test --mz_audio_test)
        DEFAULT_SHOT="ss/mz_play.png" ;;
    message)
        FLAGS=(--mz_message_test)
        DEFAULT_SHOT="ss/mz_message.png" ;;
    equip)
        FLAGS=(--mz_equip_test)
        DEFAULT_TIMEOUT_MS=180000
        DEFAULT_SHOT="ss/mz_equip.png" ;;
    message_play)
        FLAGS=(--mz_message_play)
        DEFAULT_TIMEOUT_MS=180000
        DEFAULT_SHOT="ss/mz_message_play.png" ;;
    shop)
        FLAGS=(--mz_shop_test)
        DEFAULT_TIMEOUT_MS=180000
        DEFAULT_SHOT="ss/mz_shop.png" ;;
    encounter)
        FLAGS=(--mz_encounter_test)
        DEFAULT_TIMEOUT_MS=180000
        DEFAULT_SHOT="ss/mz_encounter.png" ;;
    common)
        FLAGS=(--mz_common_event_test)
        DEFAULT_SHOT="ss/mz_common.png" ;;
    transfer)
        FLAGS=(--mz_transfer_test)
        DEFAULT_SHOT="ss/mz_transfer.png" ;;
    menu)
        FLAGS=(--mz_menu_test)
        DEFAULT_SHOT="ss/mz_menu.png" ;;
    menu_play)
        FLAGS=(--mz_menu_test --mz_menu_play)
        DEFAULT_TIMEOUT_MS=180000
        DEFAULT_SHOT="ss/mz_menu_play.png" ;;
    animation)
        FLAGS=(--mz_animation_test)
        DEFAULT_SHOT="ss/mz_animation.png" ;;
    save)
        # Non-visual, but a frame is still captured: a save that leaves the
        # scene broken shows up in the picture.
        FLAGS=(--mz_save_test)
        DEFAULT_SHOT="ss/mz_save.png" ;;
    battle)
        FLAGS=("--mz_battle_test=${TROOP}")
        DEFAULT_SHOT="ss/mz_battle.png" ;;
    battle_play)
        FLAGS=("--mz_battle_test=${TROOP}" --mz_battle_play)
        DEFAULT_TIMEOUT_MS=280000
        DEFAULT_SHOT="ss/mz_battle_play.png" ;;
    *)
        echo "error: unknown MZ_MODE '${MODE}'" \
             "(play|message|message_play|transfer|common|encounter|shop|equip" \
             "|menu|menu_play|animation|save|battle|battle_play)" >&2
        exit 1 ;;
esac
SHOT="${MZ_SCREENSHOT:-${DEFAULT_SHOT}}"
TIMEOUT_MS="${MZ_TIMEOUT_MS:-${DEFAULT_TIMEOUT_MS}}"

if [ ! -x "${ENGINE}" ] ; then
    echo "error: ${ENGINE} not built; run cmake --build build first" >&2
    exit 1
fi

if [ ! -f "${GAME}/js/rmmz_core.js" ] ; then
    echo "skip ${GAME}: no js/rmmz_core.js (run scripts/download-mz-corescript.bash first)"
    exit 0
fi
if [ ! -f "${GAME}/data/System.json" ] ; then
    echo "FAILED: ${GAME}: no data/System.json (the committed database is missing)" >&2
    exit 1
fi

mkdir -p "$(dirname "${SHOT}")"

log="$(mktemp)"
echo "== ${GAME} (mode ${MODE})"
# Run with NO X server reachable: SDL's headless "dummy" video driver instead of
# Xvfb, and DISPLAY/XAUTHORITY scrubbed. MZ's renderer is off-screen (surfaceless
# EGL + an FBO), but whenever an X server is present Mesa dispatches even a
# surfaceless eglMakeCurrent through GLX to it and is denied (X BadAccess on
# X_GLXMakeCurrent) — which is why booting under Xvfb failed while the headless
# gl_test (no X) binds cleanly. With no X, Mesa uses the pure-software surfaceless
# path and MZ boots. The SERVER_NUM arg is kept for compatibility but unused.
# (LVGL v9.5 requires a window; the dummy driver provides one without a display.)
if ! env -u DISPLAY -u XAUTHORITY SDL_VIDEODRIVER=dummy \
        timeout "$(( TIMEOUT_MS / 1000 + 30 ))" "${ENGINE}" \
        --game_dir "${GAME}" --timeout_ms="${TIMEOUT_MS}" --test_play \
        --no_render_wait \
        "${FLAGS[@]}" \
        --mz_screenshot="${SHOT}" \
        >"${log}" 2>&1 ; then
    echo "FAILED: ${GAME}: the engine exited non-zero" >&2
    grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -60 || true
    rm -f "${log}"
    exit 1
fi

fail() {
    echo "FAILED: ${GAME} (mode ${MODE}): $1" >&2
    grep -iE '\[MZ|error|exception|webgl|indexeddb' "${log}" | tail -40 || true
    grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -40 || true
    rm -f "${log}"
    exit 1
}

grep -q '\[MZ-BOOT\] booted to' "${log}" ||
    fail "never booted through the renderer ([MZ-BOOT] missing)"

# Scene_Boot is MZ's *loading* scene, so stopping there means the boot never
# finished its database/image/font/storage loads — the boot marker alone would
# happily report it.
if grep -q '\[MZ-BOOT\] booted to Scene_Boot' "${log}" ; then
    fail "the boot stopped on the loading scene (Scene_Boot)"
fi

# Every probe runs from the map, so New Game reaching it is common ground. Only
# the play mode logs [MZ-MAP] (the movement probe prints it); the others prove
# they got there by reaching Scene_Map.
grep -q '\[MZ-SCENE\] Scene_Map' "${log}" ||
    fail "New Game never reached the map (no [MZ-SCENE] Scene_Map)"

case "${MODE}" in
    play)
        grep -q '\[MZ-MAP\] reached the map' "${log}" ||
            fail "New Game never reached the map ([MZ-MAP] missing)"
        grep -q '\[MZ-MOVE\].*moved=true' "${log}" ||
            fail "input never moved the player ([MZ-MOVE] moved=true missing)"
        # The audio bridge: rmmz's AudioManager -> the op queue -> RGSS::Audio.
        # Without it MZ's sound goes to the silent Web Audio stub and nothing
        # reaches the mixer.
        grep -q '\[MZ-AUDIO\]' "${log}" ||
            fail "no audio op reached RGSS::Audio ([MZ-AUDIO] missing)"
        ;;
    message)
        # Both halves matter: the text is still queued *and* Window_Message has
        # actually opened over the map.
        grep -q '\[MZ-MSG\] busy=true window_open=true' "${log}" ||
            fail "the message window never opened ([MZ-MSG] busy/window_open)"
        ;;
    equip)
        # `equipped=true` is only that the slot holds the weapon. `stronger=true`
        # is the claim worth making: the actor's attack went up, which takes
        # Game_Actor.paramPlus summing the equipped item's params into the stat
        # the rest of the engine reads. A slot can hold an object while the
        # number the player sees never moves, and from the slot's side those two
        # look identical. See ADR 0004 M6.3q.
        grep -q '\[MZ-EQUIP\].*equipped=true' "${log}" ||
            fail "the weapon never went into the slot ([MZ-EQUIP] equipped=true)"
        grep -q '\[MZ-EQUIP\].*stronger=true' "${log}" ||
            fail "equipping did not raise the actor's attack ([MZ-EQUIP] stronger=true)"
        ;;
    message_play)
        # `picked=true` is the whole test: the second branch of the choice ran,
        # which takes Window_ChoiceList moving its cursor off the default,
        # $gameMessage's callback recording the answer, and command402 skipping
        # the branch that was not chosen. The first entry is the default, so a
        # run that never moved the cursor takes the *other* branch and reports
        # picked=false with the value that branch wrote. `closed=true` adds that
        # the message window went away again rather than the map being left
        # under a window nobody could dismiss. See ADR 0004 M6.3p.
        grep -q '\[MZ-MSGPLAY\].*choice_shown=true' "${log}" ||
            fail "the choice list never appeared ([MZ-MSGPLAY] choice_shown=true)"
        grep -q '\[MZ-MSGPLAY\].*picked=true' "${log}" ||
            fail "the chosen branch never ran ([MZ-MSGPLAY] picked=true)"
        grep -q '\[MZ-MSGPLAY\].*closed=true' "${log}" ||
            fail "the message window never closed ([MZ-MSGPLAY] closed=true)"
        ;;
    shop)
        # Both halves, because either alone would pass on a broken shop: gold
        # can leave the purse without goods arriving, and an item can arrive
        # without being paid for. Together they are a purchase — through
        # Window_ShopBuy's affordability test, Window_ShopNumber's arithmetic
        # and Scene_Shop.doBuy, none of which the menu's item path touches.
        # `returned=true` adds that the scene handed back to the map rather
        # than trapping the player in the shop. See ADR 0004 M6.3o.
        grep -q '\[MZ-SHOP\].*bought=true' "${log}" ||
            fail "nothing was bought in the shop ([MZ-SHOP] bought=true)"
        grep -q '\[MZ-SHOP\].*returned=true' "${log}" ||
            fail "the shop never handed back to the map ([MZ-SHOP] returned=true)"
        ;;
    encounter)
        # No Battle Processing command is issued anywhere in this mode, so a
        # battle can only have come from the map's own encounter list — the
        # engine deciding to fight rather than a game telling it to. The troop
        # check is what makes it the *map's* list rather than any battle at all.
        # See ADR 0004 M6.3n.
        grep -q '\[MZ-ENC\].*encountered=true' "${log}" ||
            fail "walking never triggered a random encounter ([MZ-ENC] encountered=true)"
        grep -q '\[MZ-ENC\].*troop=1 ' "${log}" ||
            fail "the encounter picked a troop outside the map's list ([MZ-ENC] troop=1)"
        ;;
    common)
        # Two separate engine paths, reported separately because driving one
        # says nothing about the other. `parallel=true` means a
        # Game_CommonEvent became active on its switch and its own interpreter
        # ran; `called=true` means command117 built a child interpreter inside
        # the map's and ran the called event through it. Both had no coverage
        # while the bed's CommonEvents.json was empty. See ADR 0004 M6.3m.
        grep -q '\[MZ-COMMON\].*parallel=true' "${log}" ||
            fail "the parallel common event never ran ([MZ-COMMON] parallel=true)"
        grep -q '\[MZ-COMMON\].*called=true' "${log}" ||
            fail "Call Common Event never ran ([MZ-COMMON] called=true)"
        ;;
    transfer)
        # Three claims, in increasing strength. `moved=true` is only the map id
        # changing; `landed=true` adds that the player is on the requested tile;
        # `arrived=true` is the destination map's *own* parallel event having
        # run, which is the difference between the id moving and the map having
        # been fetched, built and set running. A bed with one map never loaded a
        # second one, so `DataManager.loadMapData` and Scene_Map re-creating
        # itself had no coverage at all. See ADR 0004 M6.3l.
        grep -q '\[MZ-XFER\].*moved=true' "${log}" ||
            fail "Transfer Player never changed the map ([MZ-XFER] moved=true)"
        grep -q '\[MZ-XFER\].*landed=true' "${log}" ||
            fail "the player did not land on the target tile ([MZ-XFER] landed=true)"
        grep -q '\[MZ-XFER\].*arrived=true' "${log}" ||
            fail "the destination map's own events never ran ([MZ-XFER] arrived=true)"
        ;;
    menu)
        grep -q '\[MZ-MENU\] reached_menu=true' "${log}" ||
            fail "the party menu never opened ([MZ-MENU] reached_menu=true)"
        ;;
    menu_play)
        grep -q '\[MZ-MENU\] reached_menu=true' "${log}" ||
            fail "the party menu never opened ([MZ-MENU] reached_menu=true)"
        # Opening Scene_Menu is the *small* claim — it holds the instant the
        # scene is pushed. These are the menu being used: `healed=true` means an
        # item's effect reached an actor's HP through the command window, the
        # item list and the actor window; `used=true` means the inventory paid
        # for it (a heal without a spend would mean the item was never really
        # consumed); `returned=true` means cancel unwound the window stack all
        # the way back to the map instead of the menu trapping the player.
        grep -q '\[MZ-MENUPLAY\] hp_before=' "${log}" ||
            fail "the run ended before the menu walk did — no [MZ-MENUPLAY] report (raise MZ_TIMEOUT_MS)"
        grep -q '\[MZ-MENUPLAY\].*healed=true' "${log}" ||
            fail "the item never healed the actor ([MZ-MENUPLAY] healed=true)"
        grep -q '\[MZ-MENUPLAY\].*used=true' "${log}" ||
            fail "the item was never consumed ([MZ-MENUPLAY] used=true)"
        grep -q '\[MZ-MENUPLAY\].*returned=true' "${log}" ||
            fail "the menu never handed back to the map ([MZ-MENUPLAY] returned=true)"
        ;;
    animation)
        # Three separate claims, and the last is the one that matters. `mv=true`
        # says the data picked the sprite-sheet animation system rather than
        # Effekseer (whose WASM runtime this host does not start, so an
        # Effekseer animation would silently play no visuals); `cells=` counts
        # cell sprites visible with a bitmap, so `played=true` means the burst
        # actually reached the screen rather than merely existing in the scene
        # graph.
        grep -q '\[MZ-ANIM\].*mv=true' "${log}" ||
            fail "animation 1 is not an MV-format animation ([MZ-ANIM] mv=true)"
        grep -q '\[MZ-ANIM\].*played=true' "${log}" ||
            fail "the animation never drew a cell ([MZ-ANIM] played=true)"
        ;;
    save)
        grep -q '\[MZ-SAVE\] saved=true exists=true loaded=true' "${log}" ||
            fail "the save/load round-trip failed ([MZ-SAVE] line)"
        # `loaded=true` only says the promise chain settled — the slot
        # decompressed and `extractSaveContents` ran. It is true of a load that
        # restores nothing, and of one that quietly starts a new game instead.
        # `restored=true` is the round-trip: gold, a switch, a variable, an
        # actor's HP, the inventory and the player's position are moved off
        # their defaults before the save, overwritten between the save and the
        # load, and read back identical afterwards. A mismatch prints both
        # states, so the failure names the field that did not come back.
        grep -q '\[MZ-SAVE\].*restored=true' "${log}" ||
            fail "the save did not restore the game state ([MZ-SAVE] restored=true)"
        ;;
    battle)
        grep -q '\[MZ-BTL\] reached_battle=true' "${log}" ||
            fail "the battle never started ([MZ-BTL] reached_battle=true)"
        ;;
    battle_play)
        grep -q '\[MZ-BTL\] reached_battle=true' "${log}" ||
            fail "the battle never started ([MZ-BTL] reached_battle=true)"
        # Reaching Scene_Battle is the *small* claim; these two are the fight.
        # `damaged=true` means an action resolved onto an enemy's HP, which
        # takes the party command window, the actor command window, the target
        # window, BattleManager's turn order and the damage formula all working.
        # `ended=true` means the victory sequence ran and handed the scene back
        # to the map, rather than the fight stalling — which is exactly how this
        # mode found the bed's battles frozen (see ADR 0004 M6.3i).
        # A run cut off by --timeout_ms prints no report at all, and saying
        # "no attack ever damaged an enemy" about a fight that was still
        # swinging would be a lie about the cause. Separate the two.
        grep -q '\[MZ-BTLPLAY\] hp_before=' "${log}" ||
            fail "the run ended before the fight did — no [MZ-BTLPLAY] report (raise MZ_TIMEOUT_MS)"
        grep -q '\[MZ-BTLPLAY\].*damaged=true' "${log}" ||
            fail "no attack ever damaged an enemy ([MZ-BTLPLAY] damaged=true)"
        grep -q '\[MZ-BTLPLAY\].*ended=true' "${log}" ||
            fail "the battle never finished ([MZ-BTLPLAY] ended=true)"
        ;;
esac

grep -E '\[MZ-BOOT\]|\[MZ-SCENE\]|\[MZ-MAP\]|\[MZ-MOVE\]|\[MZ-AUDIO\]|\[MZ-MSG\]|\[MZ-XFER\]|\[MZ-COMMON\]|\[MZ-ENC\]|\[MZ-SHOP\]|\[MZ-MSGPLAY\]|\[MZ-EQUIP\]|\[MZ-MENU\]|\[MZ-MENUPLAY\]|\[MZ-ANIM\]|\[MZ-SAVE\]|\[MZ-BTL\]|\[MZ-BTLPLAY\]|\[MZ\] screenshot' "${log}"
# ALSA has no device under CI and floods stderr; keep the rest for context.
grep -v 'ALSA lib\|snd_\|Unknown PCM' "${log}" | tail -20 || true
rm -f "${log}"

# Everything above read the *log*. The captured frame is the other half of the
# claim, and the two can disagree: with the M6.3e fix reverted every assertion
# above still passes while the map is missing from the picture. Check what this
# run actually drew; the cross-mode comparisons (a message window that changed
# the frame, a menu that replaced it) need more than one mode's frame and run
# from scripts/mz_frame_check.rb once they have all been captured.
if command -v ruby >/dev/null 2>&1 ; then
    ruby "$(dirname "$0")/mz_frame_check.rb" --frame "${SHOT}" ||
        { echo "FAILED: ${GAME} (mode ${MODE}): the captured frame does not" \
               "show what the log claims" >&2 ; exit 1 ; }
else
    echo "note: no ruby, so ${SHOT} was not checked"
fi

echo "mz boot check (${MODE}): OK"
exit 0
