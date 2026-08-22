- **Move routes:** a "Move Forward" sub-command right after an explicit
  Face/Turn sub-command now continues in the newly faced direction, not the
  direction last physically walked before the turn -- matching RPG_RT,
  whose `UpdateMoveRoute` uses one single shared direction field for both a
  Face/Turn command and a following Move Forward, with no lock exemption
  either way.
