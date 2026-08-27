#define _GNU_SOURCE
#include <errno.h>
#include <linux/capability.h>
#include <sched.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef EMPTY_PRELOAD
#error EMPTY_PRELOAD must be defined
#endif

static void die(const char *msg) {
  perror(msg);
  _exit(127);
}

static int drop_caps(void) {
  struct __user_cap_header_struct hdr = {_LINUX_CAPABILITY_VERSION_3, 0};
  struct __user_cap_data_struct data[2];
  memset(data, 0, sizeof(data));
  if (syscall(SYS_capset, &hdr, data) != 0)
    return -1;
#ifdef PR_CAP_AMBIENT_CLEAR_ALL
  prctl(PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0, 0);
#endif
  return 0;
}

static int is_regular_file(const char *path) {
  struct stat st;
  if (lstat(path, &st) != 0)
    return 0;
  return S_ISREG(st.st_mode);
}

static void bind_empty(const char *path, char *last, size_t last_sz) {
  if (!path || !path[0] || !is_regular_file(path))
    return;
  if (last[0] && strcmp(last, path) == 0)
    return;
  if (mount(EMPTY_PRELOAD, path, NULL, MS_BIND, NULL) != 0)
    die("mount");
  snprintf(last, last_sz, "%s", path);
}

int main(int argc, char **argv) {
  char resolved[4096];
  char last[4096] = {0};

  if (argc < 2) {
    fprintf(stderr, "usage: hide-system-malloc PROGRAM [ARGS...]\n");
    return 2;
  }

  if (access("/etc/ld-nix.so.preload", F_OK) != 0 &&
      access("/etc/static/ld-nix.so.preload", F_OK) != 0) {
    execvp(argv[1], argv + 1);
    die("execvp");
  }

  if (unshare(CLONE_NEWNS) != 0)
    die("unshare");
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0)
    die("make-rprivate");

  bind_empty("/etc/ld-nix.so.preload", last, sizeof last);
  if (realpath("/etc/ld-nix.so.preload", resolved))
    bind_empty(resolved, last, sizeof last);
  if (realpath("/etc/static/ld-nix.so.preload", resolved))
    bind_empty(resolved, last, sizeof last);

  if (drop_caps() != 0)
    die("capset");

  execvp(argv[1], argv + 1);
  die("execvp");
}
