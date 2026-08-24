// libc symbols libmruby.a references that pspsdk's newlib does not provide.
//
// mrbgems/hal-posix-dir's mrb_hal_dir_chroot gates the platforms without a
// chroot(2) on __ANDROID__ / __MSDOS__ but not PSP, so declaring mruby-dir in
// build_config.rb's rpg_maker_gems pulls dir_hal.o into the EBOOT link and
// the reference dangles ("undefined reference to `chroot'"). Until upstream
// mruby's gate learns __PSP__, provide the same ENOSYS answer here that the
// gate gives those other platforms.

#include <errno.h>

int chroot(const char *path) {
  (void)path;
  errno = ENOSYS;
  return -1;
}
