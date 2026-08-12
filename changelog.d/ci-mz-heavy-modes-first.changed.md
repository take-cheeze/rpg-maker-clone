- CI's post-build `parallel` check group now lists the slow MZ play-out smokes
  (`battle_play`, `encounter`, `equip`, `menu_play`, `message_play`) first.
  That group runs with a worker-count cap rather than true unlimited
  concurrency, so a step queues behind whatever the list already put ahead of
  it; these five were consistently the last steps still running, so the
  group's total time included however long each sat waiting for a slot it
  could have had immediately. Listing them first lets them claim a slot as
  soon as the group starts instead of queueing behind a dozen short checks.
