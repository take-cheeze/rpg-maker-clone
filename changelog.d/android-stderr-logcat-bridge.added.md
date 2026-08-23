- **Android:** native stderr (all ng-log output and error reports) reached
  `/dev/null` — SDL's activity never redirects it to logcat — so a failing
  boot exited silently with no diagnostic anywhere. `main.cxx` now bridges fd
  2 through logcat under the `RPG2K` tag before logging initialises.
