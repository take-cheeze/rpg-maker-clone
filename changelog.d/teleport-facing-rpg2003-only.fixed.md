- **Events:** Teleport's and Change Event Location's arrival-facing
  sub-parameter is now ignored outright on an RPG2000 database, matching
  RPG_RT -- previously it converted and applied whatever facing value
  happened to be present in the command's parameter array regardless of
  edition, instead of only ever reading that parameter on RPG2003.
