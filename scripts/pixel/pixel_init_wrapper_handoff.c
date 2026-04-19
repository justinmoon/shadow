#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <unistd.h>

#ifndef SHADOW_INIT_WRAPPER_PRESENTED_PATH
#define SHADOW_INIT_WRAPPER_PRESENTED_PATH "/init"
#endif

#ifndef SHADOW_INIT_WRAPPER_STOCK_INIT_PATH
#define SHADOW_INIT_WRAPPER_STOCK_INIT_PATH "/init.stock"
#endif

// Keep explicit binary sentinels in the stripped ELF so shell tooling can
// validate the correct wrapper variant before patching a boot image.
static const char kWrapperSentinel[] __attribute__((used)) =
    "shadow-init-wrapper-mode:minimal";
static const char kWrapperImplSentinel[] __attribute__((used)) =
    "shadow-init-wrapper-impl:tinyc-direct";
static const char kWrapperPathSentinel[] __attribute__((used)) =
    "shadow-init-wrapper-path:" SHADOW_INIT_WRAPPER_PRESENTED_PATH;
static const char kWrapperTargetSentinel[] __attribute__((used)) =
    "shadow-init-wrapper-target:" SHADOW_INIT_WRAPPER_STOCK_INIT_PATH;
static const char kInitPath[] = SHADOW_INIT_WRAPPER_PRESENTED_PATH;
static const char kStockInitPath[] = SHADOW_INIT_WRAPPER_STOCK_INIT_PATH;
static const char kKmsgLine[] =
    "<6>[shadow-init] c handoff wrapper starting (shadow-init-wrapper-mode:minimal, "
    "path:" SHADOW_INIT_WRAPPER_PRESENTED_PATH ", target:"
    SHADOW_INIT_WRAPPER_STOCK_INIT_PATH ")\n";
static const char kExecvFailedEnoent[] =
    "<6>[shadow-init] c handoff wrapper execv("
    SHADOW_INIT_WRAPPER_STOCK_INIT_PATH ") failed: ENOENT\n";
static const char kExecvFailedEacces[] =
    "<6>[shadow-init] c handoff wrapper execv("
    SHADOW_INIT_WRAPPER_STOCK_INIT_PATH ") failed: EACCES\n";
static const char kExecvFailedGeneric[] =
    "<6>[shadow-init] c handoff wrapper execv("
    SHADOW_INIT_WRAPPER_STOCK_INIT_PATH ") failed\n";

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
  (void)kWrapperPathSentinel;
  (void)kWrapperTargetSentinel;
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
