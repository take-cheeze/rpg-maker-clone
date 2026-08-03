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

No graphics/audio assets are referenced (they'd be copyrighted RTP), so the map
renders blank and the player is invisible — this bed exercises the engine and
game *logic* (boot, scene flow, map/movement, the interpreter), not art. Run
from the repo root; it writes data/mv-sample/data/*.json. Deterministic (no
timestamps) so re-running is a no-op in git.
"""

import json
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "data", "mv-sample", "data")


def write(name, obj):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")


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

# --- Actors / Classes ------------------------------------------------------
write("Actors.json", [None, {
    "id": 1, "name": "Hero", "nickname": "", "note": "", "profile": "",
    "classId": 1, "initialLevel": 1, "maxLevel": 99,
    "characterName": "", "characterIndex": 0,
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

# --- Tileset (blank; all tiles passable so the whole map is walkable) ------
write("Tilesets.json", [None, {
    "id": 1, "name": "Blank", "note": "", "mode": 1,
    "flags": [0] * 8192,
    "tilesetNames": ["", "", "", "", "", "", "", "", ""],
}])

# --- MapInfos + Map001 -----------------------------------------------------
write("MapInfos.json", [None, {
    "id": 1, "name": "Sample Map", "order": 1, "parentId": 0,
    "expanded": False, "scrollX": 0, "scrollY": 0,
}])

W, H = 17, 13
# 6 layers (4 tile + shadow + region), all zero -> empty, fully-walkable map.
map_data = [0] * (W * H * 6)


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
