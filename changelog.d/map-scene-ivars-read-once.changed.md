- The map scene's shop, forced player route and choice/message drawing read
  their optional state once per method into a local, and a shop's state takes
  its `Game::Shop` when it is built. The compiled map scene keeps one nil test
  per method instead of one per read, and Wio flash shrinks.
