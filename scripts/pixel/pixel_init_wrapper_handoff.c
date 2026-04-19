#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <unistd.h>

static const char kWrapperSentinel[] = "shadow-init-wrapper-mode:minimal";
static const char kWrapperImplSentinel[] = "shadow-init-wrapper-impl:tinyc-direct";
static const char kInitPath[] = "/init";
static const char kStockInitPath[] = "/init.stock";
static const char kKmsgLine[] =
    "<6>[shadow-init] c handoff wrapper starting (shadow-init-wrapper-mode:minimal)\n";
static const char kExecvFailedEnoent[] =
    "<6>[shadow-init] c handoff wrapper execv(/init.stock) failed: ENOENT\n";
static const char kExecvFailedEacces[] =
    "<6>[shadow-init] c handoff wrapper execv(/init.stock) failed: EACCES\n";
static const char kExecvFailedGeneric[] =
    "<6>[shadow-init] c handoff wrapper execv(/init.stock) failed\n";

static void write_kmsg_line(const char *line, size_t len) {
  int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  if (fd < 0) {
    return;
  }

  (void)!write(fd, line, len);
  close(fd);
}

int main(int argc, char **argv) {
  char *fallback_argv[] = {(char *)kInitPath, NULL};

  (void)kWrapperSentinel;
  (void)kWrapperImplSentinel;
  write_kmsg_line(kKmsgLine, sizeof(kKmsgLine) - 1);

  if (argc > 0 && argv != NULL) {
    argv[0] = (char *)kInitPath;
    execv(kStockInitPath, argv);
  }

  execv(kStockInitPath, fallback_argv);
  if (errno == ENOENT) {
    write_kmsg_line(kExecvFailedEnoent, sizeof(kExecvFailedEnoent) - 1);
  } else if (errno == EACCES) {
    write_kmsg_line(kExecvFailedEacces, sizeof(kExecvFailedEacces) - 1);
  } else {
    write_kmsg_line(kExecvFailedGeneric, sizeof(kExecvFailedGeneric) - 1);
  }
  return 127;
}
