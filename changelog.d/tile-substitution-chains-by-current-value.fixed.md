- **Map:** Tile Substitution (Replace Chipset Tiles) now chains the way
  RPG_RT does -- a later substitution whose source tile matches an earlier
  substitution's target retargets the earlier one too, instead of being
  applied independently. Substituting a tile back to its own original id no
  longer undoes a prior substitution (matching RPG_RT, this never actually
  worked that way -- reverting requires substituting from the tile's current,
  already-rewritten id).
