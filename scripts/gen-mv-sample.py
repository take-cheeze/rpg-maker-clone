#!/usr/bin/env python3
"""Generate the minimal committed RPG Maker MV sample project's data files.

Our MV support runs the game's own JavaScript, so a test bed needs a valid MV
`data/*.json` database. Rather than depend on downloading a whole third-party
game (as the RPG2k/XP beds do), this authors a tiny, fully-controlled MV
project we own: one walkable map with a parallel test event, a one-actor party,
and just enough database for the engine to boot to `Scene_Title` and, on New
Game, into `Scene_Map`. The MIT engine (rpg_core.js + PIXI) is fetched
separately by scripts/download-mv-corescript.bash; only this authored data is
committed.

No copyrighted RTP art is referenced, but we author tiny hand-encoded PNGs (no
Pillow dependency) so the sample is actually visible: a two-tile A5 tileset (a
grass floor and a stone wall) so the map renders as a tiled room, a small walk
sheet for the player so the hero shows on the map, and a plain blue windowskin
so message/menu boxes render as framed boxes. This exercises the engine's canvas
Tilemap, Sprite_Character and Window (9-slice) paths, not just blank space. Run
from the repo root; it writes data/mv-sample/data/*.json and the PNGs under
data/mv-sample/img/. Deterministic (no timestamps) so re-running is a no-op in
git.
"""

import json
import os
import struct
import zlib

ROOT = os.path.join(os.path.dirname(__file__), "..", "data", "mv-sample")
OUT = os.path.join(ROOT, "data")


def write(name, obj):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")


def write_png(rel_path, w, h, pixels):
    """Write an 8-bit RGBA PNG (hand-encoded, so no Pillow dependency).

    `pixels` is a bytes/bytearray of length w*h*4. Used to author the tiny
    tileset below without pulling in an image library the nix devShell lacks.
    """
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)  # per-scanline filter type 0 (none)
        raw.extend(pixels[y * stride:(y + 1) * stride])

    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data +
                struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))

    path = os.path.join(ROOT, rel_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))


def sound():
    return {"name": "", "pan": 0, "pitch": 100, "volume": 90}


# --- System.json -----------------------------------------------------------
MESSAGE_KEYS = [
    "actionFailure", "actorDamage", "actorDrain", "actorGain", "actorLoss",
    "actorNoDamage", "actorNoHit", "actorRecovery", "alwaysDash", "bgmVolume",
    "bgsVolume", "buffAdd", "buffRemove", "commandRemember", "counterAttack",
    "criticalToActor", "criticalToEnemy", "debuffAdd", "defeat", "emerge",
    "enemyDamage", "enemyDrain", "enemyGain", "enemyLoss", "enemyNoDamage",
    "enemyNoHit", "enemyRecovery", "escapeFailure", "escapeStart", "evasion",
    "expNext", "expTotal", "file", "levelUp", "loadMessage", "magicEvasion",
    "magicReflection", "meVolume", "obtainExp", "obtainGold", "obtainItem",
    "obtainSkill", "partyName", "possession", "preemptive", "saveMessage",
    "seVolume", "substitute", "surprise", "useItem", "victory",
]

system = {
    "airship": {"bgm": sound(), "characterIndex": 0, "characterName": "",
                "startMapId": 0, "startX": 0, "startY": 0},
    "armorTypes": ["", "General Armor", "Magic Armor", "Light Armor",
                   "Heavy Armor", "Small Shield", "Large Shield"],
    "attackMotions": [{"type": 0, "weaponImageId": 0} for _ in range(13)],
    "battleBgm": sound(),
    "battleback1Name": "", "battleback2Name": "",
    "battlerHue": 0, "battlerName": "",
    "boat": {"bgm": sound(), "characterIndex": 0, "characterName": "",
             "startMapId": 0, "startX": 0, "startY": 0},
    "currencyUnit": "G",
    "defeatMe": sound(),
    "editMapId": 1,
    "elements": ["", "Physical", "Fire", "Ice", "Thunder", "Water", "Earth",
                 "Wind", "Light", "Darkness"],
    "equipTypes": ["", "Weapon", "Shield", "Head", "Body", "Accessory"],
    "gameTitle": "MV Sample (test bed)",
    "gameoverMe": sound(),
    "locale": "en_US",
    "magicSkills": [1],
    "menuCommands": [True, True, True, True, True, True],
    "optDisplayTp": True, "optDrawTitle": True, "optExtraExp": False,
    "optFloorDeath": False, "optFollowers": False, "optSideView": False,
    "optSlipDeath": False, "optTransparent": False,
    "partyMembers": [1],
    "ship": {"bgm": sound(), "characterIndex": 0, "characterName": "",
             "startMapId": 0, "startX": 0, "startY": 0},
    "skillTypes": ["", "Magic", "Special"],
    "sounds": [sound() for _ in range(24)],
    "startMapId": 1, "startX": 8, "startY": 6,
    "switches": [""] * 21,
    "terms": {
        "basic": ["Level", "Lv", "HP", "HP", "MP", "MP", "TP", "TP",
                  "EXP", "EXP"],
        "commands": ["Fight", "Escape", "Attack", "Guard", "Item", "Skill",
                     "Equip", "Status", "Formation", "Save", "Game End",
                     "Options", "Weapon", "Armor", "Key Item", "Equip",
                     "Optimize", "Clear", "New Game", "Continue", None,
                     "To Title", "Cancel", None, "Buy", "Sell"],
        "params": ["Max HP", "Max MP", "Attack", "Defense", "M.Attack",
                   "M.Defense", "Agility", "Luck", "Hit", "Evasion"],
        "messages": {k: "" for k in MESSAGE_KEYS},
    },
    "testBattlers": [{"actorId": 1, "equips": [0, 0, 0, 0, 0], "level": 1}],
    "testTroopId": 1,
    "title1Name": "", "title2Name": "",
    "titleBgm": sound(),
    "variables": [""] * 21,
    "versionId": 1,
    "victoryMe": sound(),
    "weaponTypes": ["", "Dagger", "Sword", "Axe", "Whip", "Staff"],
    "windowTone": [0, 0, 0, 0],
}
write("System.json", system)

# --- Character sprite ------------------------------------------------------
# A tiny authored walk sheet so the player is visible on the map (exercising
# Sprite_Character's sheet frame selection). The "$" prefix marks a single-
# character (big) sheet: 3 walk columns x 4 direction rows, each cell 48x48
# (Sprite_Character.patternWidth = width/3 for such files).
CHAR_NAME = "$Hero"


def gen_character():
    cw, ch, cols, rows = 48, 48, 3, 4
    w, h = cw * cols, ch * rows   # 144 x 192
    px = bytearray(w * h * 4)

    def rect(x0, y0, rw, rh, c):
        for yy in range(y0, y0 + rh):
            for xx in range(x0, x0 + rw):
                if 0 <= xx < w and 0 <= yy < h:
                    i = (yy * w + xx) * 4
                    px[i], px[i + 1], px[i + 2], px[i + 3] = c[0], c[1], c[2], 255

    skin, shirt, legs = (245, 205, 170), (200, 60, 60), (60, 60, 110)
    for row in range(rows):        # direction: down/left/right/up
        for col in range(cols):    # walk frame 0..2
            ox, oy, cx = col * cw, row * ch, col * cw + cw // 2
            rect(cx - 6, oy + 10, 12, 12, skin)    # head
            rect(cx - 9, oy + 22, 18, 16, shirt)   # body
            lift = (0, 2, 0)[col]                  # simple alternating stride
            rect(cx - 8, oy + 38 - lift, 6, 8, legs)
            rect(cx + 2, oy + 38 - (2 - lift), 6, 8, legs)
    write_png("img/characters/%s.png" % CHAR_NAME, w, h, bytes(px))


gen_character()


# --- Windowskin ------------------------------------------------------------
# img/system/Window.png is the skin every Window_Base draws from. Its 192x192
# quadrants: top-left = background (stretched to fill the window), bottom-left =
# a tiling overlay, top-right = the 9-slice frame (24px corners/edges), bottom-
# right = the selection cursor. We author a plain blue box: a solid background
# and a lighter solid border, transparent overlay/cursor. This makes the sample's
# message box render as an actual framed box (exercising Window's 9-slice blt),
# rather than bare text.
def gen_windowskin():
    w = h = 192
    q = 96                      # quadrant size
    px = bytearray(w * h * 4)   # transparent

    def fill(x0, y0, rw, rh, c):
        for yy in range(y0, y0 + rh):
            for xx in range(x0, x0 + rw):
                i = (yy * w + xx) * 4
                px[i], px[i + 1], px[i + 2], px[i + 3] = c[0], c[1], c[2], 255

    fill(0, 0, q, q, (40, 56, 112))     # top-left: window background (blue)
    fill(q, 0, q, q, (160, 176, 224))   # top-right: 9-slice frame (light blue)
    # bottom-left overlay and bottom-right cursor stay transparent.
    write_png("img/system/Window.png", w, h, bytes(px))


gen_windowskin()

# --- Actors / Classes ------------------------------------------------------
write("Actors.json", [None, {
    "id": 1, "name": "Hero", "nickname": "", "note": "", "profile": "",
    "classId": 1, "initialLevel": 1, "maxLevel": 99,
    "characterName": CHAR_NAME, "characterIndex": 0,
    "faceName": "", "faceIndex": 0,
    "battlerName": "", "equips": [0, 0, 0, 0, 0], "traits": [],
}])

# Class param curve: 8 params x 100 levels. MV indexes params[p][level], so a
# length-100 row covers levels 0..99; a flat curve keeps the actor non-degenerate.
def _param_curve(p):
    base = [400, 80, 30, 30, 30, 30, 30, 30][p]
    return [base] * 100


params = [_param_curve(p) for p in range(8)]
write("Classes.json", [None, {
    "id": 1, "name": "Hero", "note": "",
    "expParams": [30, 20, 30, 30],
    "params": params,
    "learnings": [{"level": 1, "note": "", "skillId": 1}],
    "traits": [
        {"code": 23, "dataId": 0, "value": 1},   # param rate: hit 100%
        {"code": 22, "dataId": 0, "value": 0.95},  # xparam hit
        {"code": 41, "dataId": 1, "value": 0},   # add skill type: Magic
        {"code": 51, "dataId": 1, "value": 0},   # add weapon type: Dagger
        {"code": 55, "dataId": 1, "value": 0},   # enable dual wield off
    ],
}])

# --- Skills (1=Attack, 2=Guard are hard-referenced by the engine) ----------
def skill(sid, name, stype, note=""):
    return {
        "id": sid, "name": name, "note": note, "description": "",
        "stypeId": stype, "mpCost": 0, "tpCost": 0, "scope": 1,
        "occasion": 1, "speed": 0, "successRate": 100, "repeats": 1,
        "tpGain": 0, "hitType": 1, "animationId": 0,
        "message1": "", "message2": "", "iconIndex": 0,
        "requiredWtypeId1": 0, "requiredWtypeId2": 0,
        "damage": {"type": 1, "elementId": 0, "formula": "a.atk * 2 - b.def",
                   "variance": 20, "critical": True},
        "effects": [],
    }


write("Skills.json", [None,
    skill(1, "Attack", 0),
    dict(skill(2, "Guard", 0), scope=11, occasion=1,
         damage={"type": 0, "elementId": 0, "formula": "0", "variance": 20,
                 "critical": False}),
])

# --- Enemies / Troops (battle data present; not auto-triggered) -------------
write("Enemies.json", [None, {
    "id": 1, "name": "Slime", "note": "",
    "battlerName": "", "battlerHue": 0,
    "params": [100, 0, 20, 20, 20, 20, 20, 20],
    "exp": 10, "gold": 5,
    "actions": [{"conditionParam1": 0, "conditionParam2": 0,
                 "conditionType": 0, "rating": 5, "skillId": 1}],
    "dropItems": [{"dataId": 0, "denominator": 1, "kind": 0}],
    "traits": [],
}])
write("Troops.json", [None, {
    "id": 1, "name": "Slime", "members": [
        {"enemyId": 1, "x": 408, "y": 300, "hidden": False}],
    "pages": [{"conditions": {"actorHp": 50, "actorId": 1, "actorValid": False,
               "enemyHp": 50, "enemyIndex": 0, "enemyValid": False,
               "switchId": 1, "switchValid": False, "turnA": 0, "turnB": 0,
               "turnEnding": False, "turnValid": False},
               "list": [{"code": 0, "indent": 0, "parameters": []}],
               "span": 0}],
}])

# --- States (state 1 = death/Knockout, hard-referenced) --------------------
write("States.json", [None, {
    "id": 1, "name": "Knockout", "note": "",
    "autoRemovalTiming": 0, "chanceByDamage": 100, "iconIndex": 1,
    "maxTurns": 1, "minTurns": 1, "motion": 3, "overlay": 0, "priority": 100,
    "message1": "", "message2": "", "message3": "", "message4": "",
    "releaseByDamage": False, "removeAtBattleEnd": False,
    "removeByDamage": False, "removeByRestriction": False,
    "removeByWalking": False, "restriction": 4, "stepsToRemove": 100,
    "traits": [],
}])

# --- Empty-but-valid database files ----------------------------------------
write("Items.json", [None])
write("Weapons.json", [None])
write("Armors.json", [None])
write("Animations.json", [None])
write("CommonEvents.json", [None])

# --- Tileset (a minimal authored A5 set: grass floor + stone wall) ---------
# We author two 48x48 A5 tiles so the map renders as visible tiles (exercising
# the engine's canvas Tilemap path), instead of a blank screen. tileId 1536
# (A5 index 0) is the floor, 1537 (A5 index 1) is the wall — see the A5 source
# formula in Tilemap._drawNormalTile: tileId 1536/1537 map to the first two
# 48x48 cells of the A5 image's top row.
TILE = 48
A5_COLS, A5_ROWS = 8, 16            # standard A5 sheet is 384x768
A5_W, A5_H = TILE * A5_COLS, TILE * A5_ROWS
FLOOR_ID, WALL_ID = 1536, 1537      # Tilemap.TILE_ID_A5 (+0, +1)


def _a5_pixels():
    px = bytearray(A5_W * A5_H * 4)  # transparent by default

    def cell(col, row, fill, edge):
        x0, y0 = col * TILE, row * TILE
        for yy in range(TILE):
            for xx in range(TILE):
                on_edge = xx == 0 or yy == 0 or xx == TILE - 1 or yy == TILE - 1
                c = edge if on_edge else fill
                i = ((y0 + yy) * A5_W + (x0 + xx)) * 4
                px[i], px[i + 1], px[i + 2], px[i + 3] = c[0], c[1], c[2], 255

    # A5 index 0 (tileId 1536): grass floor, with a slightly darker cell border
    # so the tile grid is visible in a screenshot.
    cell(0, 0, (86, 132, 74), (66, 104, 58))
    # A5 index 1 (tileId 1537): stone wall.
    cell(1, 0, (120, 116, 110), (86, 84, 80))
    return bytes(px)


write_png("img/tilesets/Sample_A5.png", A5_W, A5_H, _a5_pixels())

# Passability flags are indexed by tileId. Floor is fully passable (0); the wall
# blocks all four directions (low nibble bits: down/left/right/up). Everything
# else stays passable so the interior is freely walkable.
tileset_flags = [0] * 8192
tileset_flags[WALL_ID] = 0x0f
write("Tilesets.json", [None, {
    "id": 1, "name": "Sample", "note": "", "mode": 1,
    "flags": tileset_flags,
    # Order: A1,A2,A3,A4,A5,B,C,D,E — only A5 (index 4) is authored.
    "tilesetNames": ["", "", "", "", "Sample_A5", "", "", "", ""],
}])

# --- MapInfos + Map001 -----------------------------------------------------
write("MapInfos.json", [None, {
    "id": 1, "name": "Sample Map", "order": 1, "parentId": 0,
    "expanded": False, "scrollX": 0, "scrollY": 0,
}])

W, H = 17, 13
# 6 layers (4 tile + shadow + region). Fill the ground layer (z=0): a stone-wall
# border around a grass-floor interior, so the map renders as a visible tiled
# room. The other layers stay 0. Indexing matches Game_Map.tileId:
# data[(z*H + y)*W + x].
map_data = [0] * (W * H * 6)
for _y in range(H):
    for _x in range(W):
        border = _x == 0 or _y == 0 or _x == W - 1 or _y == H - 1
        map_data[(0 * H + _y) * W + _x] = WALL_ID if border else FLOOR_ID


def command(code, params, indent=0):
    return {"code": code, "indent": indent, "parameters": params}


def event_page(trigger, commands):
    return {
        "conditions": {"actorId": 1, "actorValid": False, "itemId": 1,
                       "itemValid": False, "selfSwitchCh": "A",
                       "selfSwitchValid": False, "switch1Id": 1,
                       "switch1Valid": False, "switch2Id": 1,
                       "switch2Valid": False, "variableId": 1,
                       "variableValid": False, "variableValue": 0},
        "directionFix": False,
        "image": {"characterName": "", "characterIndex": 0, "direction": 2,
                  "pattern": 1, "tileId": 0},
        "list": commands,
        "moveFrequency": 3,
        "moveRoute": {"list": [command(0, [])], "repeat": True,
                      "skippable": False, "wait": False},
        "moveSpeed": 3, "moveType": 0, "priorityType": 0,
        "stepAnime": False, "through": False, "trigger": trigger,
        "walkAnime": True,
    }


# A parallel-process event (trigger 4) that keeps setting variable 1 = 42 via
# Control Variables (122). Exercises the interpreter each frame without
# blocking on UI, so a headless boot proves the map + interpreter run.
test_event = {
    "id": 1, "name": "ParallelTest", "note": "", "x": 8, "y": 6,
    "pages": [event_page(4, [
        command(122, [1, 1, 0, 0, 42]),  # var[1] = 42
        command(0, []),
    ])],
}

write("Map001.json", {
    "autoplayBgm": False, "autoplayBgs": False,
    "bgm": sound(), "bgs": sound(),
    "battleback1Name": "", "battleback2Name": "",
    "data": map_data,
    "disableDashing": False, "displayName": "",
    "encounterList": [], "encounterStep": 30,
    "events": [None, test_event],
    "height": H, "width": W, "note": "",
    "parallaxLoopX": False, "parallaxLoopY": False, "parallaxName": "",
    "parallaxShow": True, "parallaxSx": 0, "parallaxSy": 0,
    "scrollType": 0, "specifyBattleback": False, "tilesetId": 1,
})

print("generated MV sample data ->", os.path.normpath(OUT))
