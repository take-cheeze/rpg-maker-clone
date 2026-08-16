- **Weather Effects now clamps its type and strength the same way real
  RPG_RT does.** An RPG2003-only weather type used to persist on an RPG2000
  game instead of reading as no weather, and an out-of-range strength byte
  used to be saved past the strongest defined level instead of clamping.
