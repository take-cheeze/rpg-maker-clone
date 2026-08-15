// mruby-io's default I/O HAL (hal-posix-io, auto-selected by
// 3rd/mruby/mrbgems/mruby-io/mrbgem.rake since nothing in build_config.rb
// picks one explicitly) calls six POSIX functions pspdev's newlib declares
// in its headers (so hal-posix-io compiles) but does not implement (so
// linking the EBOOT fails with "undefined reference"): dup/dup2/sysconf
// back mrb_hal_io_spawn_process's fork-and-exec dance, and
// ftruncate/flock/dup are also reachable from IO#dup, File#flock and
// File#truncate. None of that is reachable from this bring-up -- there is
// no process model on the PSP to spawn into, and no game code yet -- so
// minimal set-errno-and-fail definitions are enough to satisfy the linker
// without claiming functionality the platform does not have. Only built for
// PSP_BUILD; every other target already has a real implementation of these.
#if defined(PSP_BUILD)

#include <errno.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>

int ftruncate(int fd, off_t length) {
  (void)fd;
  (void)length;
  errno = ENOSYS;
  return -1;
}

int flock(int fd, int operation) {
  (void)fd;
  (void)operation;
  errno = ENOSYS;
  return -1;
}

int dup(int fd) {
  (void)fd;
  errno = ENOSYS;
  return -1;
}

int dup2(int fd, int fd2) {
  (void)fd;
  (void)fd2;
  errno = ENOSYS;
  return -1;
}

long sysconf(int name) {
  (void)name;
  errno = ENOSYS;
  return -1;
}

pid_t waitpid(pid_t pid, int* status, int options) {
  (void)pid;
  (void)status;
  (void)options;
  errno = ENOSYS;
  return -1;
}

#endif  // PSP_BUILD
