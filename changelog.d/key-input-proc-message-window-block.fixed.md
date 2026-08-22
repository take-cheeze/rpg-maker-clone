- **Events:** a waiting Key Input Processing command now blocks and retries
  while a message window or choice list is open, matching RPG_RT -- most
  visibly, a Parallel Process's own waiting Key Input Processing no longer
  resolves a keypress while a different event's message window still sits
  on screen.
