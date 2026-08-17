- The **Toggle ATB Mode event command (5003) is implemented**: it flips the
  same save-system `atb_mode` field the field menu's Wait command targets, so
  a gauge battle switches live between wait and active mid-fight — EasyRPG's
  `Game_System::ToggleAtbMode()` (`data.atb_mode = !data.atb_mode`). The
  opcode now has a `Cmd::TOGGLE_ATB_MODE` constant (the last of liblcf's
  2k3e 500x block to be wired) and a `do_toggle_atb_mode` handler that runs
  the event straight on. Covered by new `rpg2k_logic_check.rb` checks
  (the constant matches the LCF Code enum; the command flips the field both
  ways and does not pause) and a `rpg2k_scene_check.rb` check driving a
  5003-bearing battle page through a live gauge fight.
