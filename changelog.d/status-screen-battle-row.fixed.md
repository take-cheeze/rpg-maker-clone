- **Status screen:** On an RPG2003 database, the field Status screen now
  shows a right-aligned "Front"/"Back" label for the displayed actor's
  current battle row, matching RPG_RT's `Window_ActorInfo::DrawInfo` --
  previously the screen never drew it at all, even though the row itself was
  already tracked and toggleable from the field menu's own Row command. An
  RPG2000 database still shows neither label.
