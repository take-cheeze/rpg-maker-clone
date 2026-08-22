- **Movement:** A diagonal Move Route step (Up-Right/Down-Right/Down-Left/
  Up-Left) now keeps whichever axis the character was already facing,
  matching RPG_RT -- a character facing Left that steps Up-Right now ends up
  facing Right, not Up. Previously every diagonal step unconditionally faced
  the diagonal's vertical component, discarding a horizontal facing outright.
