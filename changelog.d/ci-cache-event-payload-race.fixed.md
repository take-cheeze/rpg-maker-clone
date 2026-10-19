- **CI:** run native JavaScript cache actions after checkout with complete
  file-hash keys, and keep them in the foreground so runner
  event-payload rewrites cannot race their JSON parsing and abort the build
  before compilation. Independent shell work remains parallel.
