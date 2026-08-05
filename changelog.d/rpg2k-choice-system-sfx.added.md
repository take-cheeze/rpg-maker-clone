The map choice window now plays the RPG2000 system sounds: the cursor sound
as the selection moves between options and the decision sound when a choice is
confirmed. Each resolves a Change System SFX (10670) override held on the game
state before falling back to the database's own sound, so events that swap the
system sounds are honoured.
