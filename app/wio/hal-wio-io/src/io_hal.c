/*
** io_hal.c - Wio Terminal (bare-metal arm-none-eabi) HAL for mruby-io.
**
** Unlike hal-posix-io's target platforms, this board's newlib has no dirent,
** lstat, symlink, fork/exec, or select -- there is no process model and FAT
** (via app/wio/src/sd_syscalls.cxx's newlib syscall hooks, WIO_WITH_SD) has
** no symlinks or Unix permissions to begin with. Real RPG2000/2003 play
** (mruby-rpg2k/mrblib, mruby-lcf/mrblib, mruby-rgss/mrblib -- see their own
** File.* call sites) only ever opens, reads, writes, checks existence of and
** deletes plain files by absolute path, so this HAL implements exactly that
** on top of the newlib syscalls the board already provides (open/close/read/
** write/lseek/fstat/unlink), composing path-based stat from open+fstat+close
** rather than needing a real stat()/lstat() the platform has neither of, and
** returns ENOSYS for the rest of the contract (locking, process spawning,
** symlinks, multiplexing) -- operations no game here ever reaches, the same
** "drop what nothing calls" reasoning ADR 0098 already applied to onigmo.
*/

#include <mruby.h>
#include "io_hal.h"

#include <sys/stat.h>

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static void convert_stat(const struct stat* src, mrb_io_stat* dst) {
  /* st_atime/st_mtime/st_ctime are themselves macros on this newlib
   * (st_atime -> st_atim.tv_sec, ...), so they must be read from `src`
   * before dst's own same-named mrb_io_stat fields are ever written --
   * writing dst->st_atime would otherwise expand to dst->st_atim.tv_sec too,
   * a member mrb_io_stat does not have. Same trap hal-posix-io's own
   * convert_stat documents. */
  const int64_t atime = (int64_t)src->st_atime;
  const int64_t mtime = (int64_t)src->st_mtime;
  const int64_t ctime = (int64_t)src->st_ctime;
  /* Drop the macros now that src's fields are read: mrb_io_stat's own
   * same-named fields below are plain int64_t members, not timespecs, and
   * the macro's textual substitution does not know the difference. */
#undef st_atime
#undef st_mtime
#undef st_ctime
  memset(dst, 0, sizeof(*dst));
  dst->st_dev = (uint64_t)src->st_dev;
  dst->st_ino = (uint64_t)src->st_ino;
  dst->st_mode = (uint32_t)src->st_mode;
  dst->st_nlink = (uint32_t)src->st_nlink;
  dst->st_uid = (uint32_t)src->st_uid;
  dst->st_gid = (uint32_t)src->st_gid;
  dst->st_rdev = (uint64_t)src->st_rdev;
  dst->st_size = (int64_t)src->st_size;
  dst->st_atime = atime;
  dst->st_mtime = mtime;
  dst->st_ctime = ctime;
  dst->st_blksize = 512;
  dst->st_blocks = (src->st_size + 511) / 512;
}

/*
 * Core I/O operations -- real, backed by sd_syscalls.cxx's newlib hooks.
 */

int mrb_hal_io_open(mrb_state* mrb, const char* path, int flags, uint32_t mode) {
  (void)mrb;
  return open(path, flags, (mode_t)mode);
}

int mrb_hal_io_close(mrb_state* mrb, int fd) {
  (void)mrb;
  return close(fd);
}

int64_t mrb_hal_io_read(mrb_state* mrb, int fd, void* buf, size_t count) {
  (void)mrb;
  return (int64_t)read(fd, buf, count);
}

int64_t mrb_hal_io_write(mrb_state* mrb, int fd, const void* buf, size_t count) {
  (void)mrb;
  return (int64_t)write(fd, buf, count);
}

int64_t mrb_hal_io_lseek(mrb_state* mrb, int fd, int64_t offset, int whence) {
  (void)mrb;
  int w = SEEK_SET;
  if (whence == MRB_IO_SEEK_CUR)
    w = SEEK_CUR;
  else if (whence == MRB_IO_SEEK_END)
    w = SEEK_END;
  return (int64_t)lseek(fd, (off_t)offset, w);
}

int mrb_hal_io_fstat(mrb_state* mrb, int fd, mrb_io_stat* st) {
  (void)mrb;
  struct stat sb;
  if (fstat(fd, &sb) != 0)
    return -1;
  convert_stat(&sb, st);
  return 0;
}

/* No real stat()/lstat() on this newlib (no dirent-style filesystem glue);
 * composed from the syscalls that do exist, an open+fstat+close round trip
 * being the only path-based query File.exist?/File.file? actually need.
 * FAT has no symlinks, so lstat answers exactly what stat does. */
int mrb_hal_io_stat(mrb_state* mrb, const char* path, mrb_io_stat* st) {
  int fd = open(path, O_RDONLY);
  if (fd < 0)
    return -1;
  int rc = mrb_hal_io_fstat(mrb, fd, st);
  int saved_errno = errno;
  close(fd);
  errno = saved_errno;
  return rc;
}

int mrb_hal_io_lstat(mrb_state* mrb, const char* path, mrb_io_stat* st) {
  return mrb_hal_io_stat(mrb, path, st);
}

/*
 * mruby-io's own core src/io.c calls plain dup()/waitpid() directly (IO#dup
 * -- symdup -- and fptr_finalize's process-reaping path for a pid-bearing
 * IO object), not through this HAL's own mrb_hal_io_dup/spawn_process/
 * waitpid contract -- those two call sites are genuinely unreachable here
 * (a pid-bearing IO object never exists: mrb_hal_io_spawn_process above
 * always fails), but newlib declares both in <unistd.h>/<sys/wait.h>
 * without ever defining them for this bare-metal target, so the link still
 * needs something. Same "operations no game here ever reaches" reasoning
 * as the rest of this file, just satisfying the linker rather than the
 * HAL's own C API this time.
 */
int dup(int fd) {
  (void)fd;
  errno = ENOSYS;
  return -1;
}

int waitpid(int pid, int* status, int options) {
  (void)pid;
  (void)status;
  (void)options;
  errno = ENOSYS;
  return -1;
}

int mrb_hal_io_unlink(mrb_state* mrb, const char* path) {
  (void)mrb;
  return unlink(path);
}

/*
 * Everything below is real contract surface no game reachable from this
 * board's exporter/build (RPG2000/2003 only, ADR 0061/0091/0097) ever calls:
 * no process model, no symlinks, no advisory locking, no async I/O
 * multiplexing. Each returns ENOSYS rather than silently pretending to
 * succeed, so a call this HAL does not expect fails loudly instead of
 * corrupting state.
 */

int mrb_hal_io_chmod(mrb_state* mrb, const char* path, uint32_t mode) {
  (void)mrb;
  (void)path;
  (void)mode;
  errno = ENOSYS;
  return -1;
}

uint32_t mrb_hal_io_umask(mrb_state* mrb, int32_t mask) {
  (void)mrb;
  (void)mask;
  return 0;
}

int mrb_hal_io_ftruncate(mrb_state* mrb, int fd, int64_t length) {
  (void)mrb;
  (void)fd;
  (void)length;
  errno = ENOSYS;
  return -1;
}

int mrb_hal_io_flock(mrb_state* mrb, int fd, int operation) {
  (void)mrb;
  (void)fd;
  (void)operation;
  errno = ENOSYS;
  return -1;
}

int mrb_hal_io_rename(mrb_state* mrb, const char* oldpath, const char* newpath) {
  (void)mrb;
  (void)oldpath;
  (void)newpath;
  errno = ENOSYS;
  return -1;
}

int mrb_hal_io_symlink(mrb_state* mrb, const char* target, const char* linkpath) {
  (void)mrb;
  (void)target;
  (void)linkpath;
  errno = ENOSYS;
  return -1;
}

int64_t mrb_hal_io_readlink(mrb_state* mrb, const char* path, char* buf, size_t bufsize) {
  (void)mrb;
  (void)path;
  (void)buf;
  (void)bufsize;
  errno = ENOSYS;
  return -1;
}

char* mrb_hal_io_realpath(mrb_state* mrb, const char* path, char* resolved) {
  (void)mrb;
  (void)path;
  (void)resolved;
  errno = ENOSYS;
  return NULL;
}

/* Every path this engine opens is already absolute (GAME_DIR-rooted), so
 * there is no real working-directory concept to answer -- "/" is a safe,
 * harmless placeholder rather than failing a caller that just wants some
 * string back. */
char* mrb_hal_io_getcwd(mrb_state* mrb, char* buf, size_t size) {
  (void)mrb;
  if (size < 2) {
    errno = ERANGE;
    return NULL;
  }
  buf[0] = '/';
  buf[1] = '\0';
  return buf;
}

const char* mrb_hal_io_getenv(mrb_state* mrb, const char* name) {
  (void)mrb;
  (void)name;
  return NULL;
}

const char* mrb_hal_io_gethome(mrb_state* mrb, const char* username) {
  (void)mrb;
  (void)username;
  return NULL;
}

int mrb_hal_io_dup(mrb_state* mrb, int fd) {
  (void)mrb;
  (void)fd;
  errno = ENOSYS;
  return -1;
}

int mrb_hal_io_fcntl(mrb_state* mrb, int fd, int cmd, int arg) {
  (void)mrb;
  (void)fd;
  (void)cmd;
  (void)arg;
  errno = ENOSYS;
  return -1;
}

int mrb_hal_io_isatty(mrb_state* mrb, int fd) {
  (void)mrb;
  (void)fd;
  return 0;
}

int mrb_hal_io_pipe(mrb_state* mrb, int fds[2]) {
  (void)mrb;
  (void)fds;
  errno = ENOSYS;
  return -1;
}

int mrb_hal_io_spawn_process(mrb_state* mrb, const char* cmd, int stdin_fd,
                             int stdout_fd, int stderr_fd, int* pid) {
  (void)mrb;
  (void)cmd;
  (void)stdin_fd;
  (void)stdout_fd;
  (void)stderr_fd;
  (void)pid;
  errno = ENOSYS;
  return -1;
}

int mrb_hal_io_waitpid(mrb_state* mrb, int pid, int* status, int options) {
  (void)mrb;
  (void)pid;
  (void)status;
  (void)options;
  errno = ENOSYS;
  return -1;
}

struct mrb_io_fdset {
  int unused;
};

mrb_io_fdset* mrb_hal_io_fdset_alloc(mrb_state* mrb) {
  (void)mrb;
  errno = ENOSYS;
  return NULL;
}

void mrb_hal_io_fdset_free(mrb_state* mrb, mrb_io_fdset* fdset) {
  (void)mrb;
  (void)fdset;
}

void mrb_hal_io_fdset_zero(mrb_state* mrb, mrb_io_fdset* fdset) {
  (void)mrb;
  (void)fdset;
}

void mrb_hal_io_fdset_set(mrb_state* mrb, int fd, mrb_io_fdset* fdset) {
  (void)mrb;
  (void)fd;
  (void)fdset;
}

int mrb_hal_io_fdset_isset(mrb_state* mrb, int fd, mrb_io_fdset* fdset) {
  (void)mrb;
  (void)fd;
  (void)fdset;
  return 0;
}

int mrb_hal_io_select(mrb_state* mrb, int nfds, mrb_io_fdset* readfds,
                      mrb_io_fdset* writefds, mrb_io_fdset* errorfds,
                      mrb_io_timeval* timeout) {
  (void)mrb;
  (void)nfds;
  (void)readfds;
  (void)writefds;
  (void)errorfds;
  (void)timeout;
  errno = ENOSYS;
  return -1;
}

void mrb_hal_io_init(mrb_state* mrb) {
  (void)mrb;
}

void mrb_hal_io_final(mrb_state* mrb) {
  (void)mrb;
}

/*
 * Gem initialization -- the entry points mruby's own generated gem_init.c
 * calls (GENERATED_TMP_mrb_hal_wio_io_gem_init/_final), named from this
 * gem's own directory name the same way hal-posix-io's are.
 */

void mrb_hal_wio_io_gem_init(mrb_state* mrb) {
  (void)mrb;
  /* HAL interface functions are called by mruby-io gem */
}

void mrb_hal_wio_io_gem_final(mrb_state* mrb) {
  (void)mrb;
  /* Cleanup handled by mrb_hal_io_final, called from mruby-io */
}
