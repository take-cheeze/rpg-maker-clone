- **CI:** the Pages deploy waits until its `github-pages` artifact is listed
  for the run, so a listing that lags the upload no longer fails the master
  deploy with "No artifacts named github-pages".
