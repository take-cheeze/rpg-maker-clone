- **bc2cpp**: the closed-world static dispatch analysis scans every core-gem
  mrblib as text. Before, 16 core-gem mrblib files were compiled as program but
  never read as text, so a name they sent could have been unregistered
  unseen. Regenerated `static_dispatch_unregistered_closed.rb` with the full
  scan check: 1051 names (72 added, 147 no longer provably unreachable and so
  kept registered).
