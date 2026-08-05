- RPG Maker **XP** events now honour **Wait for Move's Completion** (command
  210), the third most common command in a real game after text and move routes
  (373 uses in Pray for You). The interpreter suspends on it and the map scene
  keeps the *forced* routes walking while it waits — `step_events` deliberately
  freezes autonomous movement while an event runs, and this is the one case RMXP
  keeps forcing characters along, since the interpreter is suspended on them.
  Without it a list ran straight on and an event delivered its line before it
  had finished walking over. A repeating forced route never completes (it hangs
  RMXP too), so the wait is bounded and logs why it gave up instead of freezing
  a headless run.
