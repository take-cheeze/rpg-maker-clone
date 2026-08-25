- **Item/Skill menus:** the actor-target-confirm screen ("who to use this
  on") now draws each party member's own 48x48 face portrait, when they
  have one, matching RPG_RT — every row's face sits flush at its own row's
  top, with successive rows pitched 58px apart. Previously no face was ever
  drawn, leaving a blank gutter on every row. (An earlier version of this
  fix, based on measuring only two rows, special-cased the top row as
  flush and pushed every later row in by a flat 18px; independently
  re-verified against genuine RPG_RT.exe with a full four-member party and
  found wrong past the second row, so this fragment has been corrected in
  place.)
