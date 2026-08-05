#!/usr/bin/env python3
"""Generate the committed RPG Maker MZ sample project's data files and art.

Our MZ support runs the game's own JavaScript (the fetched `rmmz_*` corescript
on PIXI v5, see docs/adr/0004-javascript-maker-mv-quickjs.md M6), so the test bed
needs a valid MZ `data/*.json` database plus the system art the engine hard-
requires. Rather than depend on a third-party game — MZ has no redistributable
project — this authors a tiny, fully-controlled MZ project we own: one walkable
map with a parallel test event, a one-actor party, and enough database and art
for the engine to boot through `Scene_Title` and, on New Game, into `Scene_Map`.
The engine itself is fetched separately by scripts/download-mz-corescript.bash;
only this authored data is committed.

The art matters as much as the data here. Two of MZ's system images are not
optional the way MV's are:

  * `img/system/ButtonSet.png` — MZ's touch UI (`ConfigManager.touchUI`, on by
    default) puts Sprite_Button instances in every scrollable window, and
    `Sprite_Button.checkBitmap` *throws* ("ButtonSet image is too small") unless
    the sheet is at least 11 blocks (11 * 48 = 528px) wide. A missing file
    resolves to our host's 1x1 placeholder, so without an authored sheet the
    first map frame aborts.
  * `img/system/Window.png` — the windowskin every Window_Base draws from, and
    the source `ColorManager` samples its text colours from.

No copyrighted RTP art is referenced: the PNGs are hand-encoded here (no Pillow
dependency, which the nix devShell lacks), exactly as scripts/gen-mv-sample.py
does for the MV bed. Run from anywhere; it writes data/mz-sample/data/*.json and
the PNGs under data/mz-sample/img/. Deterministic (no timestamps) so re-running
is a no-op in git.
"""

import json
import math
import os
import struct
import zlib

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                    "data", "mz-sample")
OUT = os.path.join(ROOT, "data")

TILE = 48  # MZ's default tile size (System.tileSize)


def write(name, obj):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")


def write_png(rel_path, w, h, pixels):
    """Write an 8-bit RGBA PNG (hand-encoded, so no Pillow dependency).

    `pixels` is a bytes/bytearray of length w*h*4.
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


class Canvas:
    """A tiny RGBA pixel buffer with the few primitives the art below needs."""

    def __init__(self, w, h):
        self.w = w
        self.h = h
        self.px = bytearray(w * h * 4)  # transparent

    def set(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            i = (y * self.w + x) * 4
            self.px[i] = c[0]
            self.px[i + 1] = c[1]
            self.px[i + 2] = c[2]
            self.px[i + 3] = c[3] if len(c) > 3 else 255

    def fill(self, x0, y0, w, h, c):
        for y in range(y0, y0 + h):
            for x in range(x0, x0 + w):
                self.set(x, y, c)

    def frame(self, x0, y0, w, h, c, thickness=1):
        for t in range(thickness):
            self.fill(x0 + t, y0 + t, w - 2 * t, 1, c)
            self.fill(x0 + t, y0 + h - 1 - t, w - 2 * t, 1, c)
            self.fill(x0 + t, y0 + t, 1, h - 2 * t, c)
            self.fill(x0 + w - 1 - t, y0 + t, 1, h - 2 * t, c)

    def bytes(self):
        return bytes(self.px)


def write_wav(rel_path, freq=440, ms=120, rate=8000, vol=0.4):
    """Write a tiny 16-bit mono PCM WAV (hand-encoded, no audio library).

    A short sine beep with a 64-sample linear fade in/out to avoid clicks. MZ's
    AudioManager is routed to RGSS::Audio (MV::AUDIO_BRIDGE_JS), whose SDL_mixer
    backend resolves a name to a file by trying its extensions, so a committed
    `.wav` is playable without shipping any copyrighted RTP sound.
    Deterministic (math.sin is IEEE) so re-running is a no-op in git.
    """
    n = int(rate * ms / 1000)
    frames = bytearray()
    for i in range(n):
        env = min(1.0, i / 64.0, (n - i) / 64.0)
        frames += struct.pack("<h", int(vol * env * 32767 *
                                        math.sin(2 * math.pi * freq * i / rate)))
    data = bytes(frames)
    fmt = struct.pack("<HHIIHH", 1, 1, rate, rate * 2, 2, 16)  # PCM mono 16-bit
    body = (b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt +
            b"data" + struct.pack("<I", len(data)) + data)
    path = os.path.join(ROOT, rel_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(body)) + body)


def sound(name=""):
    return {"name": name, "volume": 90, "pitch": 100, "pan": 0}


def vehicle():
    return {"bgm": sound(), "characterName": "", "characterIndex": 0,
            "startMapId": 0, "startX": 0, "startY": 0}


# --- System.json -----------------------------------------------------------
# MZ's terms.commands indices are the ones TextManager reads (18 = New Game,
# 19 = Continue, 11 = Options, 21 = To Title, 22 = Cancel...), so the title
# command window shows real words instead of blanks.
COMMANDS = [
    "Fight", "Escape", "Attack", "Guard", "Item", "Skill", "Equip", "Status",
    "Formation", "Save", "Game End", "Options", "Weapon", "Armor", "Key Item",
    "Equip", "Optimize", "Clear", "New Game", "Continue", "", "To Title",
    "Cancel", "", "Buy", "Sell",
]

# The message terms MZ's option/status windows read. Only the ones a boot to the
# map can reach need text; the rest are present (empty) so a lookup never
# resolves to undefined.
MESSAGE_KEYS = [
    "actionFailure", "actorDamage", "actorDrain", "actorGain", "actorLoss",
    "actorNoDamage", "actorNoHit", "actorRecovery", "alwaysDash", "autosave",
    "bgmVolume", "bgsVolume", "buffAdd", "buffRemove", "commandRemember",
    "counterAttack", "criticalToActor", "criticalToEnemy", "debuffAdd",
    "defeat", "emerge", "enemyDamage", "enemyDrain", "enemyGain", "enemyLoss",
    "enemyNoDamage", "enemyNoHit", "enemyRecovery", "escapeFailure",
    "escapeStart", "evasion", "expNext", "expTotal", "file", "levelUp",
    "loadMessage", "magicEvasion", "magicReflection", "meVolume", "obtainExp",
    "obtainGold", "obtainItem", "obtainSkill", "partyName", "possession",
    "preemptive", "saveMessage", "seVolume", "substitute", "surprise",
    "touchUI", "useItem", "victory",
]

system = {
    "gameTitle": "MZ Testbed",
    "versionId": 1,
    "locale": "en_US",
    "hasEncryptedImages": False,
    "hasEncryptedAudio": False,
    "encryptionKey": "",
    "title1Name": "",
    "title2Name": "",
    "optDrawTitle": True,
    "titleBgm": sound(),
    "titleCommandWindow": {"background": 0, "offsetX": 0, "offsetY": 0},
    "battleback1Name": "",
    "battleback2Name": "",
    "battleBgm": sound(),
    "victoryMe": sound(),
    "defeatMe": sound(),
    "gameoverMe": sound(),
    # The 24 system SEs. The common UI sounds (0 Cursor, 1 OK, 2 Cancel,
    # 3 Buzzer) point at the authored Beep.wav so menu interaction actually
    # plays through the audio bridge; the rest stay silent.
    "sounds": [sound("Beep") if i < 4 else sound() for i in range(24)],
    "airship": vehicle(),
    "boat": vehicle(),
    "ship": vehicle(),
    "windowTone": [0, 0, 0, 0],
    "currencyUnit": "G",
    "partyMembers": [1],
    "startMapId": 1,
    "startX": 8,
    "startY": 6,
    "editMapId": 1,
    "switches": [None, "sw"],
    "variables": [None, "var"],
    "armorTypes": [None, "General Armor"],
    "weaponTypes": [None, "Dagger"],
    "skillTypes": [None, "Magic"],
    "equipTypes": [None, "Weapon", "Shield", "Head", "Body", "Accessory"],
    "elements": [None, "", "Fire", "Ice"],
    "attackMotions": [None, {"type": 0, "weaponImageId": 0}],
    "magicSkills": [1],
    "terms": {
        "basic": ["Level", "Lv", "HP", "HP", "MP", "MP", "TP", "TP"],
        "commands": COMMANDS,
        "params": ["Max HP", "Max MP", "Attack", "Defense", "M.Attack",
                   "M.Defense", "Agility", "Luck"],
        "messages": {k: "" for k in MESSAGE_KEYS},
    },
    "itemCategories": [True, True, True, True],
    "menuCommands": [True, True, True, True, True, True],
    "battleSystem": 0,
    "optDisplayTp": True,
    "optExtraExp": False,
    "optFloorDeath": False,
    "optFollowers": True,
    "optKeyItemsLimit": False,
    "optSideView": False,
    "optSlipDeath": False,
    "optTransparent": False,
    "optAutosave": False,
    "tileSize": TILE,
    "advanced": {
        "gameId": 1,
        "screenWidth": 816,
        "screenHeight": 624,
        "uiAreaWidth": 808,
        "uiAreaHeight": 616,
        # The authored font (scripts/gen-sample-font.py) — a face we own, so it
        # can be committed where the RTP fonts cannot. Shipped as .woff because
        # that is what real MZ projects ship, which also makes CI exercise the
        # WOFF unpacker in mvcanvas.cxx.
        "mainFontFilename": "Sample.woff",
        "numberFontFilename": "Sample.woff",
        "fallbackFonts": "",
        "fontSize": 26,
        "windowOpacity": 192,
        "screenScale": 1,
        "numberInputVariableId": 0,
    },
}
write("System.json", system)

# --- Audio -----------------------------------------------------------------
# A tiny authored sound effect so the bed has real, loadable audio (see
# System.sounds above and --mz_audio_test). RGSS::Audio resolves the bridge's
# "audio/se/Beep" to this file.
write_wav("audio/se/Beep.wav")


# --- Windowskin ------------------------------------------------------------
# img/system/Window.png is the skin every Window_Base draws from, and the image
# ColorManager samples the 32 text colours out of (from the 96..192 x 96..192
# quadrant, 12x8 swatches of 8px). Its 192x192 quadrants are: top-left window
# background (stretched), bottom-left tiling overlay, top-right the 9-slice
# frame (24px corners/edges), bottom-right the cursor + colour table.
def gen_windowskin():
    q = 96
    c = Canvas(192, 192)
    c.fill(0, 0, q, q, (40, 56, 112))        # background (blue)
    c.fill(q, 0, q, q, (160, 176, 224))      # 9-slice frame (light blue)
    # Cursor: the 48x48 block at (96, 96) — a light frame MZ stretches over the
    # selected item.
    c.fill(q, q, 48, 48, (255, 255, 255, 48))
    c.frame(q, q, 48, 48, (255, 255, 255, 200), 2)
    # The 32-entry text-colour table ColorManager.textColor reads: 8x8 swatches
    # laid out 8 per row starting at (96, 144). Entry 0 (white) is the normal
    # text colour; the rest are given distinguishable hues.
    palette = [
        (255, 255, 255), (32, 160, 214), (255, 120, 76), (102, 204, 64),
        (128, 192, 240), (192, 128, 255), (204, 204, 64), (128, 128, 128),
        (192, 192, 192), (32, 208, 255), (255, 176, 128), (128, 255, 128),
        (192, 224, 255), (224, 176, 255), (255, 255, 128), (224, 224, 224),
        (32, 32, 32), (255, 64, 64), (64, 255, 64), (64, 64, 255),
        (255, 255, 64), (64, 255, 255), (255, 64, 255), (160, 160, 160),
        (208, 208, 208), (255, 128, 128), (128, 255, 128), (128, 128, 255),
        (255, 255, 128), (128, 255, 255), (255, 128, 255), (240, 240, 240),
    ]
    for i, col in enumerate(palette):
        c.fill(q + (i % 8) * 8, 144 + (i // 8) * 8, 8, 8, col)
    write_png("img/system/Window.png", c.w, c.h, c.bytes())


gen_windowskin()


# --- ButtonSet -------------------------------------------------------------
# MZ's touch UI. 11 blocks of 48x48 across (cancel x2, pageup, pagedown, down,
# up, down2, up2, ok x2, menu) and two rows: cold (top) and hot/pressed
# (bottom). Sprite_Button.checkBitmap throws unless the sheet is >= 11 blocks
# wide, so this file is mandatory for a scene with buttons — see the module
# docstring. Each block is a rounded-looking plate with a glyph hinting at its
# button, drawn brighter in the pressed row.
def gen_buttonset():
    blocks = 11
    bw = bh = 48
    c = Canvas(bw * blocks, bh * 2)
    for row in range(2):
        plate = (72, 80, 104) if row == 0 else (120, 132, 168)
        edge = (160, 176, 224)
        glyph = (236, 240, 255)
        for b in range(blocks):
            x0, y0 = b * bw, row * bh
            c.fill(x0 + 2, y0 + 2, bw - 4, bh - 4, plate)
            c.frame(x0 + 2, y0 + 2, bw - 4, bh - 4, edge, 2)
            cx, cy = x0 + bw // 2, y0 + bh // 2
            # A simple centred glyph per block so the buttons are legible:
            # a bar for the wide (cancel/ok) plates, a chevron for the arrows.
            if b in (0, 1, 8, 9):
                c.fill(cx - 8, cy - 2, 16, 4, glyph)
            else:
                up = b in (5, 7, 2)
                for i in range(8):
                    dy = -i if up else i
                    c.fill(cx - i, cy + dy // 1 - 4, 1, 2, glyph)
                    c.fill(cx + i, cy + dy // 1 - 4, 1, 2, glyph)
    write_png("img/system/ButtonSet.png", c.w, c.h, c.bytes())


gen_buttonset()


# --- IconSet ---------------------------------------------------------------
# 32x32 icons, 16 per row. Nothing in the sample references an icon, but
# Scene_Boot preloads the sheet, so an authored (non-degenerate) image keeps the
# preload honest instead of resolving to the host's 1x1 placeholder.
def gen_iconset():
    cell, cols, rows = 32, 16, 20
    c = Canvas(cell * cols, cell * rows)
    for i in range(cols):
        # A handful of visible marks in the first row; the rest stays clear.
        shade = 80 + i * 10
        c.frame(i * cell + 6, 6, 20, 20, (shade, 200 - i * 8, 220), 2)
    write_png("img/system/IconSet.png", c.w, c.h, c.bytes())


gen_iconset()


# --- Animation sheet -------------------------------------------------------
# MZ ships two animation systems, and only one of them is reachable here.
# `Spriteset_Base.isMVAnimation` picks by data shape: an animation object that
# has a `frames` array is drawn by `Sprite_AnimationMV` out of a plain sprite
# sheet, while everything else goes to `Sprite_Animation`, which needs an
# Effekseer runtime. That runtime is a WASM module `main.js` initialises, and
# our host bypasses `main.js` (ADR 0004 M6.2), so `Graphics.effekseer` stays
# null and an Effekseer animation degrades to its timings alone — no visuals.
# The MV-format path needs nothing but sprites and blend modes, so that is what
# the bed authors and what the animation smoke exercises.
#
# The sheet is the MV layout `Sprite_AnimationMV.updateCellSprite` indexes:
# 192x192 cells, five per row, pattern p at (p % 5, (p % 100) / 5).
#
# Each pattern is a *filled* disc of the same radius, differing in colour
# (cyan through magenta) rather than in size. That is deliberate and not the
# obvious choice: expanding rings look more like an animation, but a smoke test
# captures one frame at a moment it does not control, and rings make the number
# of pixels the burst covers depend on which frame it caught — a 7x spread
# between the first and last. Equal-area cells mean any captured frame is the
# same size of evidence, so the check can demand a lot of it. Consecutive frames
# still differ visibly, by colour.
ANIM_NAME = "Burst"
ANIM_CELL = 192
ANIM_PATTERNS = 5
ANIM_RADIUS = 72


def gen_animation():
    c = Canvas(ANIM_CELL * ANIM_PATTERNS, ANIM_CELL)
    for p in range(ANIM_PATTERNS):
        ox = p * ANIM_CELL
        cx = cy = ANIM_CELL // 2
        # Cyan fading to magenta across the burst, at full alpha: the map under
        # it is green, so any pixel of this on screen is unmistakable.
        col = (60 + p * 48, 230 - p * 40, 255, 255)
        for y in range(ANIM_CELL):
            for x in range(ANIM_CELL):
                if math.hypot(x - cx, y - cy) <= ANIM_RADIUS:
                    c.set(ox + x, y, col)
    write_png("img/animations/%s.png" % ANIM_NAME, c.w, c.h, c.bytes())


gen_animation()


# --- Character sprite ------------------------------------------------------
# A tiny authored walk sheet so the player is visible on the map (exercising
# Sprite_Character's frame selection). The "$" prefix marks a single-character
# (big) sheet: 3 walk columns x 4 direction rows, each cell 48x48 — MZ reads it
# the same way MV does (ImageManager.isBigCharacter).
CHAR_NAME = "$Hero"


def gen_character():
    cols, rows = 3, 4
    c = Canvas(TILE * cols, TILE * rows)
    skin, shirt, legs = (245, 205, 170), (200, 60, 60), (60, 60, 110)
    for row in range(rows):        # direction: down/left/right/up
        for col in range(cols):    # walk frame 0..2
            oy, cx = row * TILE, col * TILE + TILE // 2
            c.fill(cx - 6, oy + 10, 12, 12, skin)    # head
            c.fill(cx - 9, oy + 22, 18, 16, shirt)   # body
            lift = (0, 2, 0)[col]                    # alternating stride
            c.fill(cx - 8, oy + 38 - lift, 6, 8, legs)
            c.fill(cx + 2, oy + 38 - (2 - lift), 6, 8, legs)
    write_png("img/characters/%s.png" % CHAR_NAME, c.w, c.h, c.bytes())


gen_character()


# --- Tileset (a minimal authored A5 set: grass floor + stone wall) ---------
# tileId 1536 (A5 index 0) is the floor, 1537 (A5 index 1) the wall — MZ's
# Tilemap maps those ids to the first two 48x48 cells of the A5 sheet's top row,
# the same as MV.
A5_COLS, A5_ROWS = 8, 16            # a standard A5 sheet is 384x768
FLOOR_ID, WALL_ID = 1536, 1537


def gen_tileset():
    c = Canvas(TILE * A5_COLS, TILE * A5_ROWS)

    def cell(col, row, fill, edge):
        x0, y0 = col * TILE, row * TILE
        c.fill(x0, y0, TILE, TILE, fill)
        c.frame(x0, y0, TILE, TILE, edge)

    cell(0, 0, (86, 132, 74), (66, 104, 58))     # A5 index 0: grass floor
    cell(1, 0, (120, 116, 110), (86, 84, 80))    # A5 index 1: stone wall
    write_png("img/tilesets/Sample_A5.png", c.w, c.h, c.bytes())


gen_tileset()

# Passability flags are indexed by tileId: the floor is fully passable (0), the
# wall blocks all four directions (low nibble: down/left/right/up).
tileset_flags = [0] * 8192
tileset_flags[WALL_ID] = 0x0f
# The empty tile (id 0) must carry 0x10, "no effect on passage". Game_Map's
# checkPassage walks the four tile layers from the top down and the *first*
# tile that is not marked "no effect" decides, so a plain 0 there would make the
# empty upper layers answer "passable" for every cell and the wall below would
# never block. A real editor-written tileset flags id 0 exactly this way
# (checked against the MV test bed's Tilesets.json, whose flags[0] is 0x10).
tileset_flags[0] = 0x10
write("Tilesets.json", [None, {
    "id": 1, "name": "Sample", "note": "", "mode": 1,
    "flags": tileset_flags,
    # Order: A1,A2,A3,A4,A5,B,C,D,E — only A5 (index 4) is authored.
    "tilesetNames": ["", "", "", "", "Sample_A5", "", "", "", ""],
}])

# --- Actors / Classes ------------------------------------------------------
write("Actors.json", [None, {
    "id": 1, "name": "Hero", "nickname": "", "note": "", "profile": "",
    "classId": 1, "initialLevel": 1, "maxLevel": 99,
    "characterName": CHAR_NAME, "characterIndex": 0,
    "faceName": "", "faceIndex": 0,
    "battlerName": "", "equips": [0, 0, 0, 0, 0], "traits": [],
}])


# Class param curve: 8 params x 100 levels (MZ indexes params[p][level], so a
# length-100 row covers levels 0..99). A flat curve keeps the actor
# non-degenerate without modelling growth the bed never exercises.
def _param_curve(p):
    return [[400, 80, 30, 30, 30, 30, 30, 30][p]] * 100


write("Classes.json", [None, {
    "id": 1, "name": "Class", "note": "",
    "expParams": [30, 20, 30, 30],
    "params": [_param_curve(p) for p in range(8)],
    "learnings": [{"level": 1, "note": "", "skillId": 1}],
    "traits": [
        {"code": 51, "dataId": 1, "value": 0},   # add weapon type: Dagger
        {"code": 41, "dataId": 1, "value": 0},   # add skill type: Magic
        # Hit rate, and it is load-bearing rather than flavour. A physical
        # action's chance to connect is `successRate * 0.01 * subject.hit`
        # (Game_Action.itemHit), and `hit` is xparam 0, which is **0 unless a
        # trait grants it**. A class without this trait misses every physical
        # attack it ever makes, so a battle runs turn after turn with nothing
        # taking damage and no side able to win. Every class the editor creates
        # carries it at 95%; a hand-authored one has to say so.
        {"code": 22, "dataId": 0, "value": 0.95},  # xparam HIT 95%
        {"code": 22, "dataId": 1, "value": 0.05},  # xparam EVA 5%
    ],
}])

# --- Skills (1 = Attack, 2 = Guard are hard-referenced by the engine) ------
def skill(sid, name, scope=1, formula="a.atk * 2 - b.def", dtype=1):
    return {
        "id": sid, "name": name, "note": "", "description": "",
        "stypeId": 0, "mpCost": 0, "tpCost": 0, "scope": scope,
        "occasion": 1, "speed": 0, "successRate": 100, "repeats": 1,
        "tpGain": 0, "hitType": 1, "animationId": 0, "messageType": 0,
        "message1": "", "message2": "", "iconIndex": 0,
        "requiredWtypeId1": 0, "requiredWtypeId2": 0,
        "damage": {"type": dtype, "elementId": 0, "formula": formula,
                   "variance": 20, "critical": True},
        "effects": [],
    }


write("Skills.json", [None, skill(1, "Attack"),
                      skill(2, "Guard", scope=11, formula="0", dtype=0)])

# --- States (state 1 = Knockout, hard-referenced by the engine) ------------
write("States.json", [None, {
    "id": 1, "name": "Knockout", "note": "",
    "autoRemovalTiming": 0, "chanceByDamage": 100, "iconIndex": 0,
    "maxTurns": 1, "minTurns": 1, "motion": 3, "overlay": 0, "priority": 100,
    "message1": "", "message2": "", "message3": "", "message4": "",
    "releaseByDamage": False, "removeAtBattleEnd": False,
    "removeByDamage": False, "removeByRestriction": False,
    "removeByWalking": False, "restriction": 4, "stepsToRemove": 100,
    "traits": [],
}])

# --- Enemies / Troops (valid battle data; no encounter is set on the map) --
#
# The battler image is **not** cosmetic, which is not obvious. `Sprite_Enemy`
# only loads a bitmap when the name it reads differs from the one it is holding:
#
#     Sprite_Enemy.prototype.initMembers = function() { ... this._battlerName = ""; ... }
#     Sprite_Enemy.prototype.updateBitmap = function() {
#         const name = this._enemy.battlerName();
#         if (this._battlerName !== name || ...) { ... this.loadBitmap(name); }
#     };
#
# An enemy whose `battlerName` is the empty string therefore matches the
# sprite's initial value, never loads anything, and leaves `this.bitmap`
# undefined — and the very next line of `Sprite_Enemy.updateFrame` reads
# `this.bitmap.width`. That throws on the first frame of every battle and every
# frame after it, taking out the rest of `Scene_Battle.update` (the window layer
# stops updating, so no message is dismissed and `BattleManager` never leaves
# the "start" phase). The fight is frozen before it begins. This is rmmz's own
# behaviour, not something our host introduces — a browser breaks identically —
# and the editor never writes an empty battlerName, so only a hand-authored bed
# like this one can hit it. See ADR 0004 M6.3i.
ENEMY_NAME = "Slime"


def gen_enemy():
    """A front-view battler: a blob with a highlight, on transparent ground."""
    w = h = 144
    c = Canvas(w, h)
    cx, cy = w // 2, h // 2 + 16
    for y in range(h):
        for x in range(w):
            # A squashed ellipse — wider than it is tall, flat on the bottom.
            dx = (x - cx) / 62.0
            dy = (y - cy) / 44.0
            if dx * dx + dy * dy <= 1.0:
                shade = 120 + int(70 * (1.0 - (y - (cy - 44)) / 88.0))
                c.set(x, y, (60, min(255, shade + 40), 110, 235))
    # A highlight, so the sprite is not one flat colour and a frame check can
    # tell it apart from a filled rectangle.
    for y in range(cy - 34, cy - 14):
        for x in range(cx - 24, cx - 4):
            if (x - (cx - 14)) ** 2 + (y - (cy - 24)) ** 2 <= 100:
                c.set(x, y, (230, 255, 240, 235))
    write_png("img/enemies/%s.png" % ENEMY_NAME, w, h, c.bytes())


gen_enemy()

write("Enemies.json", [None, {
    "id": 1, "name": "Slime", "note": "",
    "battlerName": ENEMY_NAME, "battlerHue": 0,
    "params": [100, 0, 20, 20, 20, 20, 20, 20],
    "exp": 10, "gold": 5,
    "actions": [{"conditionParam1": 0, "conditionParam2": 0,
                 "conditionType": 0, "rating": 5, "skillId": 1}],
    "dropItems": [{"dataId": 0, "denominator": 1, "kind": 0}],
    # The same hit trait the class needs, for the same reason: without it the
    # slime swings and misses forever too, so neither side can end the fight.
    "traits": [{"code": 22, "dataId": 0, "value": 0.95}],
}])
write("Troops.json", [None, {
    "id": 1, "name": "Slime", "members": [
        {"enemyId": 1, "x": 408, "y": 300, "hidden": False}],
    "pages": [{"conditions": {"actorHp": 50, "actorId": 1, "actorValid": False,
                              "enemyHp": 50, "enemyIndex": 0,
                              "enemyValid": False, "switchId": 1,
                              "switchValid": False, "turnA": 0, "turnB": 0,
                              "turnEnding": False, "turnValid": False},
               "list": [{"code": 0, "indent": 0, "parameters": []}],
               "span": 0}],
}])

# --- Empty-but-valid database files ----------------------------------------
write("Items.json", [None])
write("Weapons.json", [None])
write("Armors.json", [None])

# --- Animations ------------------------------------------------------------
# One MV-format animation (see gen_animation above for why the format matters).
# Four frames, one cell each, walking patterns 0..3 of the sheet so consecutive
# frames differ; each cell is [pattern, x, y, scale%, rotation, mirror, opacity,
# blendMode]. Frame 3 is additive (blendMode 1) on purpose — the animation path
# is the only thing in this bed that asks the renderer to blend anything other
# than normal alpha, so leaving it out would let a broken blend mode pass.
# `position: 1` centres the burst on the target; `timings` is empty so the frame
# diff a smoke test measures is the animation itself and not a screen flash.
write("Animations.json", [None, {
    "id": 1, "name": ANIM_NAME,
    "displayType": 0, "effectName": "", "flashTimings": [], "soundTimings": [],
    "offsetX": 0, "offsetY": 0, "rotation": {"x": 0, "y": 0, "z": 0},
    "scale": 100, "speed": 100, "alignBottom": False,
    "animation1Name": ANIM_NAME, "animation1Hue": 0,
    "animation2Name": "", "animation2Hue": 0,
    "position": 1,
    "frames": [
        [[0, 0, 0, 100, 0, 0, 255, 0]],
        [[1, 0, 0, 100, 0, 0, 255, 0]],
        [[2, 0, 0, 100, 0, 0, 255, 0]],
        [[3, 0, 0, 100, 0, 0, 255, 1]],
    ],
    "timings": [],
}])
write("CommonEvents.json", [None])

# --- MapInfos + Map001 -----------------------------------------------------
write("MapInfos.json", [None, {
    "id": 1, "name": "Sample Map", "order": 1, "parentId": 0,
    "expanded": False, "scrollX": 0, "scrollY": 0,
}])

W, H = 17, 13
# 6 layers (4 tile + shadow + region). Fill the ground layer (z=0) with a stone
# border around a grass interior so the map renders as a visible tiled room; the
# other layers stay 0. Indexing matches Game_Map.tileId: data[(z*H + y)*W + x].
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
# Control Variables (122). It exercises the interpreter every frame without
# blocking on UI, so a headless boot proves the map and its interpreter run.
test_event = {
    "id": 1, "name": "ParallelTest", "note": "", "x": 2, "y": 2,
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
