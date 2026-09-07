- **WOLF RPG Editor (ウディタ/Woditor)** `WaitForMove`(202) — "→完了までウ
  ェイト" — is now a no-op alongside `Blank`(0)/`Checkpoint`(99): since
  `SetMoveRoute`(201) already applies every step instantly, there is
  nothing left to wait for by the time control reaches this command. See
  `docs/adr/0081-wolf-rpg-editor-wait-for-move.md`.
