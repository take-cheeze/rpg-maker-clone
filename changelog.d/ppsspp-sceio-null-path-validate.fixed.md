- **A bad path pointer from PSP code no longer takes the whole emulator down.**
  `Core/HLE/FunctionWrappers.h`'s `WrapU_C` passes
  `Memory::GetCharPointer(PARAM(0))` straight through, and that returns
  `nullptr` for an address outside guest memory — so `sceIoDopen`, `sceIoChdir`,
  `sceIoRemove` and `sceIoRmdir` handed a raw null to `pspFileSystem`, which
  built a `std::string` from it, threw `std::logic_error`, and terminated the
  host process. Same class as the `sceKernelCreateLwMutex` workarea bug this
  flake already patches: an ordinary bad argument from the guest crashes the
  emulator instead of raising a guest-visible error, which also makes the
  offending binary undebuggable *under* the emulator. Hit during PSP bring-up,
  where newlib's `_unlink()` reaches `sceIoRemove` with an unreadable path and
  turned every attempt to add guest-side diagnostics into a core dump. Fixed by
  rejecting null up front in the four functions that dereference it, returning
  `SCE_KERNEL_ERROR_ERRNO_INVALID_ARGUMENT` —
  `nix/patches/ppsspp-sceio-null-path-validate.patch`. `sceIoUnassign` uses the
  same wrapper but never dereferences, so it is left alone. Not yet upstreamed.
