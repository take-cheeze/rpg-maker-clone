- **PPSSPP's `SysclibForKernel` `strchr`/`strrchr` searched for the wrong thing
  entirely, breaking path handling in the PSP EBOOT.** Both called
  `str.find(str, c)` — the `find(const std::string&, size_t pos)` overload,
  "find this whole string inside itself starting at offset `c`" — where
  `find((char)c)` was meant. Since a string always contains itself at offset 0
  and never past it, `strchr(s, c)` returned `s` for `c == 0` and `NULL` for
  every other character, whatever `s` held. pspsdk's libcglue routes both to
  these kernel syscalls and newlib splits paths on `'/'` with them, so every
  separator lookup failed: the EBOOT's `sceIoOpen` calls arrived as unresolved
  relative paths (`NOCWD=sceIoOpen(/Title/Nepheshel_logo)`), rescued only by a
  fallback that rebuilt the full `ms0:` path another way. Fixed by calling the
  character overload, and by handling `c == 0` explicitly since C's
  `strchr`/`strrchr` match the terminating NUL that `std::string` does not
  contain — `nix/patches/ppsspp-sysclib-strchr-strrchr.patch`. Verified: the
  EBOOT's `NOCWD` path errors go from 17 to 0. Not yet upstreamed; it affects
  any PSP binary whose libc routes these through `SysclibForKernel`.
