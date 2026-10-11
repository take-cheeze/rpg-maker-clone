- **Save:** A Pan Screen lock, and a Pan Screen scroll still in flight, now
  survive a `.lsd` save and load. Previously the lock was dropped on load, and
  an unfinished scroll snapped to its offset instead of resuming.
- **Save:** A picture still moving when the game was saved and reloaded no
  longer makes the next `.lsd` save fail. Its target opacity is written as a
  whole number, as the save format requires.
