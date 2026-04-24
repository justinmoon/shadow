#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static const char kProbeSentinel[] __attribute__((used)) =
    "shadow-camera-hal-bionic-probe";
static const char kHalPath[] = "/vendor/lib64/hw/camera.sm6150.so";
static const uint64_t kAndroidDlExtUseNamespace = 0x200;
static const char *g_progress_path = NULL;

struct hw_module_t;
struct hw_device_t;

typedef struct hw_module_methods_t {
  int (*open)(const struct hw_module_t *module, const char *id,
              struct hw_device_t **device);
} hw_module_methods_t;

typedef struct hw_module_t {
  uint32_t tag;
  uint16_t module_api_version;
  uint16_t hal_api_version;
  const char *id;
  const char *name;
  const char *author;
  hw_module_methods_t *methods;
  void *dso;
  uint64_t reserved[32 - 7];
} hw_module_t;

typedef struct hw_device_t {
  uint32_t tag;
  uint32_t version;
  struct hw_module_t *module;
  uint64_t reserved[12];
  int (*close)(struct hw_device_t *device);
} hw_device_t;

typedef struct camera_info_t {
  int facing;
  int orientation;
  uint32_t device_version;
  const void *static_camera_characteristics;
  int resource_cost;
  char **conflicting_devices;
  size_t conflicting_devices_length;
} camera_info_t;

typedef struct camera_module_t {
  hw_module_t common;
  int (*get_number_of_cameras)(void);
  int (*get_camera_info)(int camera_id, camera_info_t *info);
} camera_module_t;

typedef struct android_dlextinfo_t {
  uint64_t flags;
  void *reserved_addr;
  size_t reserved_size;
  int relro_fd;
  int library_fd;
  int64_t library_fd_offset;
  void *library_namespace;
} android_dlextinfo_t;

typedef void *(*android_get_exported_namespace_fn)(const char *name);
typedef void *(*android_dlopen_ext_fn)(const char *filename, int flags,
                                       const android_dlextinfo_t *extinfo);

typedef struct options_t {
  const char *output;
  const char *progress_output;
  const char *run_token;
  const char *camera_id;
  const char *dev_mount;
  const char *mount_dev;
  const char *mount_proc;
  const char *mount_sys;
  bool call_module_entrypoints;
  bool call_open;
  uint32_t child_timeout_secs;
} options_t;

static void print_usage(FILE *stream) {
  fprintf(stream,
          "Usage: pixel_camera_hal_bionic_probe --output PATH "
          "[--run-token TOKEN] [--camera-id ID] [--call-open true|false]\n");
}

static const char *arg_value(int argc, char **argv, int *index,
                             const char *label) {
  if (*index + 1 >= argc) {
    fprintf(stderr, "pixel_camera_hal_bionic_probe: missing value for %s\n",
            label);
    exit(2);
  }
  *index += 1;
  return argv[*index];
}

static uint32_t parse_u32_value(const char *value, const char *label) {
  char *end = NULL;
  errno = 0;
  unsigned long parsed = strtoul(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || parsed > UINT32_MAX) {
    fprintf(stderr, "pixel_camera_hal_bionic_probe: invalid %s: %s\n", label,
            value);
    exit(2);
  }
  return (uint32_t)parsed;
}

static bool parse_bool_value(const char *value, const char *label) {
  if (strcmp(value, "true") == 0) {
    return true;
  }
  if (strcmp(value, "false") == 0) {
    return false;
  }
  fprintf(stderr, "pixel_camera_hal_bionic_probe: %s must be true or false: %s\n",
          label, value);
  exit(2);
}

static options_t parse_options(int argc, char **argv) {
  options_t options = {
      .output = NULL,
      .progress_output = NULL,
      .run_token = "unset",
      .camera_id = "0",
      .dev_mount = "unknown",
      .mount_dev = "false",
      .mount_proc = "false",
      .mount_sys = "false",
      .call_module_entrypoints = false,
      .call_open = false,
      .child_timeout_secs = 30,
  };

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--output") == 0) {
      options.output = arg_value(argc, argv, &i, "--output");
    } else if (strcmp(argv[i], "--run-token") == 0) {
      options.run_token = arg_value(argc, argv, &i, "--run-token");
    } else if (strcmp(argv[i], "--camera-id") == 0) {
      options.camera_id = arg_value(argc, argv, &i, "--camera-id");
    } else if (strcmp(argv[i], "--dev-mount") == 0) {
      options.dev_mount = arg_value(argc, argv, &i, "--dev-mount");
    } else if (strcmp(argv[i], "--mount-dev") == 0) {
      options.mount_dev = arg_value(argc, argv, &i, "--mount-dev");
    } else if (strcmp(argv[i], "--mount-proc") == 0) {
      options.mount_proc = arg_value(argc, argv, &i, "--mount-proc");
    } else if (strcmp(argv[i], "--mount-sys") == 0) {
      options.mount_sys = arg_value(argc, argv, &i, "--mount-sys");
    } else if (strcmp(argv[i], "--call-module-entrypoints") == 0) {
      const char *value = arg_value(argc, argv, &i, "--call-module-entrypoints");
      options.call_module_entrypoints =
          parse_bool_value(value, "--call-module-entrypoints");
    } else if (strcmp(argv[i], "--call-open") == 0) {
      const char *value = arg_value(argc, argv, &i, "--call-open");
      options.call_open = parse_bool_value(value, "--call-open");
    } else if (strcmp(argv[i], "--child-timeout-secs") == 0) {
      options.child_timeout_secs = parse_u32_value(
          arg_value(argc, argv, &i, "--child-timeout-secs"),
          "--child-timeout-secs");
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      print_usage(stdout);
      exit(0);
    } else {
      fprintf(stderr, "pixel_camera_hal_bionic_probe: unknown argument: %s\n",
              argv[i]);
      print_usage(stderr);
      exit(2);
    }
  }

  if (options.output == NULL || options.output[0] == '\0') {
    fprintf(stderr, "pixel_camera_hal_bionic_probe: --output is required\n");
    exit(2);
  }
  return options;
}

static void json_string(FILE *out, const char *value) {
  fputc('"', out);
  if (value != NULL) {
    for (const unsigned char *p = (const unsigned char *)value; *p != '\0';
         p++) {
      switch (*p) {
      case '\\':
        fputs("\\\\", out);
        break;
      case '"':
        fputs("\\\"", out);
        break;
      case '\n':
        fputs("\\n", out);
        break;
      case '\r':
        fputs("\\r", out);
        break;
      case '\t':
        fputs("\\t", out);
        break;
      default:
        if (*p < 0x20) {
          fprintf(out, "\\u%04x", *p);
        } else {
          fputc(*p, out);
        }
        break;
      }
    }
  }
  fputc('"', out);
}

static const char *file_type_name(mode_t mode) {
  if (S_ISCHR(mode)) {
    return "char";
  }
  if (S_ISBLK(mode)) {
    return "block";
  }
  if (S_ISLNK(mode)) {
    return "symlink";
  }
  if (S_ISDIR(mode)) {
    return "dir";
  }
  if (S_ISREG(mode)) {
    return "file";
  }
  return "other";
}

static void write_path_status(FILE *out, const char *path) {
  struct stat st;
  if (lstat(path, &st) == 0) {
    fputs("{\"path\":", out);
    json_string(out, path);
    fprintf(out,
            ",\"exists\":true,\"type\":\"%s\",\"mode\":\"%o\","
            "\"uid\":%lu,\"gid\":%lu,\"size\":%lld}",
            file_type_name(st.st_mode), st.st_mode & 07777,
            (unsigned long)st.st_uid, (unsigned long)st.st_gid,
            (long long)st.st_size);
    return;
  }

  int saved_errno = errno;
  fputs("{\"path\":", out);
  json_string(out, path);
  fprintf(out, ",\"exists\":false,\"errno\":%d,\"error\":", saved_errno);
  json_string(out, strerror(saved_errno));
  fputc('}', out);
}

static void write_path_statuses(FILE *out) {
  static const char *kPaths[] = {
      "/vendor/lib64/hw/camera.sm6150.so",
      "/vendor",
      "/vendor/lib64",
      "/vendor/lib64/hw",
      "/system/lib64/libhardware.so",
      "/system/lib64/libcamera_metadata.so",
      "/apex/com.android.runtime/bin/linker64",
      "/linkerconfig/ld.config.txt",
      "/dev/binder",
      "/dev/hwbinder",
      "/dev/vndbinder",
      "/dev/ion",
      "/dev/video0",
      "/dev/video1",
      "/dev/video2",
      "/dev/video32",
      "/dev/video33",
      "/dev/video34",
      "/dev/media0",
      "/dev/media1",
      "/dev/v4l-subdev0",
      "/dev/v4l-subdev16",
      "/dev/dma_heap/system",
  };
  for (size_t i = 0; i < sizeof(kPaths) / sizeof(kPaths[0]); i++) {
    if (i > 0) {
      fputs(",\n    ", out);
    }
    write_path_status(out, kPaths[i]);
  }
}

static void write_stage(FILE *out, const char *stage, const char *status,
                        const char *detail) {
  fputs("{\"stage\":", out);
  json_string(out, stage);
  fputs(",\"status\":", out);
  json_string(out, status);
  fputs(",\"detail\":", out);
  json_string(out, detail);
  fputc('}', out);
}

static const char *safe_dlerror(void) {
  const char *error = dlerror();
  return error != NULL ? error : "unknown dynamic linker error";
}

static void copy_error(char *buffer, size_t buffer_len, const char *message) {
  if (buffer_len == 0) {
    return;
  }
  snprintf(buffer, buffer_len, "%s", message != NULL ? message : "unknown error");
}

static void write_progress(const char *step) {
  if (g_progress_path == NULL || g_progress_path[0] == '\0') {
    return;
  }
  FILE *out = fopen(g_progress_path, "w");
  if (out == NULL) {
    return;
  }
  fputs(step, out);
  fputc('\n', out);
  fclose(out);
}

static void read_progress(const char *path, char *buffer, size_t buffer_len) {
  if (buffer_len == 0) {
    return;
  }
  buffer[0] = '\0';
  if (path == NULL || path[0] == '\0') {
    return;
  }
  FILE *in = fopen(path, "r");
  if (in == NULL) {
    return;
  }
  if (fgets(buffer, (int)buffer_len, in) == NULL) {
    buffer[0] = '\0';
  }
  fclose(in);
  size_t len = strlen(buffer);
  while (len > 0 && (buffer[len - 1] == '\n' || buffer[len - 1] == '\r')) {
    buffer[len - 1] = '\0';
    len--;
  }
}

static void *load_hal_exported_namespace(const char *namespace_name,
                                         char *error_buffer,
                                         size_t error_buffer_len) {
  write_progress("android-dlopen-ext:dlsym-get-exported-namespace");
  android_get_exported_namespace_fn get_namespace =
      (android_get_exported_namespace_fn)dlsym(RTLD_DEFAULT,
                                               "android_get_exported_namespace");
  if (get_namespace == NULL) {
    copy_error(error_buffer, error_buffer_len,
               "android_get_exported_namespace unavailable");
    return NULL;
  }

  write_progress("android-dlopen-ext:dlsym-android-dlopen-ext");
  android_dlopen_ext_fn android_dlopen_ext =
      (android_dlopen_ext_fn)dlsym(RTLD_DEFAULT, "android_dlopen_ext");
  if (android_dlopen_ext == NULL) {
    copy_error(error_buffer, error_buffer_len, "android_dlopen_ext unavailable");
    return NULL;
  }

  char progress[160];
  snprintf(progress, sizeof(progress), "android-dlopen-ext:get-namespace:%s",
           namespace_name);
  write_progress(progress);
  void *namespace_handle = get_namespace(namespace_name);
  if (namespace_handle == NULL) {
    snprintf(error_buffer, error_buffer_len,
             "exported namespace unavailable: %s", namespace_name);
    return NULL;
  }

  android_dlextinfo_t extinfo;
  memset(&extinfo, 0, sizeof(extinfo));
  extinfo.flags = kAndroidDlExtUseNamespace;
  extinfo.relro_fd = -1;
  extinfo.library_fd = -1;
  extinfo.library_fd_offset = 0;
  extinfo.library_namespace = namespace_handle;

  dlerror();
  snprintf(progress, sizeof(progress), "android-dlopen-ext:call:%s",
           namespace_name);
  write_progress(progress);
  void *handle = android_dlopen_ext(kHalPath, RTLD_NOW | RTLD_LOCAL, &extinfo);
  if (handle == NULL) {
    snprintf(error_buffer, error_buffer_len, "android_dlopen_ext %s: %s",
             namespace_name, safe_dlerror());
    snprintf(progress, sizeof(progress), "android-dlopen-ext:fail:%s",
             namespace_name);
    write_progress(progress);
  } else {
    snprintf(progress, sizeof(progress), "android-dlopen-ext:ok:%s",
             namespace_name);
    write_progress(progress);
  }
  return handle;
}

static void write_summary(const options_t *options) {
  g_progress_path = options->progress_output;
  write_progress("start");

  const char *blocker_stage = "link";
  const char *blocker = "dlopen failed from bionic helper";
  const char *next_step =
      "resolve the bionic linker/library/property/device-node blocker, then "
      "advance to camera_module_t open";
  const char *link_error = NULL;
  const char *link_mode = "none";
  char link_error_storage[512] = {0};
  const char *hmi_error = NULL;
  const char *id = NULL;
  const char *name = NULL;
  const char *author = NULL;
  void *handle = NULL;
  camera_module_t *module = NULL;
  int camera_count = -1;
  bool link_ok = false;
  bool hmi_ok = false;
  bool module_ok = false;
  bool camera_info_attempted = false;
  bool open_ready = false;
  bool open_attempted = false;
  bool open_ok = false;
  int open_status = 0;
  hw_device_t *opened_device = NULL;
  bool close_attempted = false;
  int close_status = 0;
  char open_blocker_storage[256] = {0};
  int camera_info_status = 0;
  camera_info_t camera_info;
  memset(&camera_info, 0, sizeof(camera_info));

  handle = load_hal_exported_namespace("sphal", link_error_storage,
                                       sizeof(link_error_storage));
  link_mode = "android-dlopen-ext:sphal";
  if (handle == NULL) {
    handle = load_hal_exported_namespace("default", link_error_storage,
                                         sizeof(link_error_storage));
    link_mode = "android-dlopen-ext:default";
  }
  if (handle == NULL) {
    dlerror();
    write_progress("current-namespace:dlopen");
    handle = dlopen(kHalPath, RTLD_NOW | RTLD_LOCAL);
    link_mode = "current-namespace";
    if (handle == NULL) {
      copy_error(link_error_storage, sizeof(link_error_storage), safe_dlerror());
      write_progress("current-namespace:fail");
    } else {
      write_progress("current-namespace:ok");
    }
  }
  if (handle == NULL) {
    link_error = link_error_storage;
  } else {
    link_ok = true;
    dlerror();
    write_progress("dlsym:HMI");
    module = (camera_module_t *)dlsym(handle, "HMI");
    if (module == NULL) {
      hmi_error = safe_dlerror();
      blocker_stage = "hmi";
      blocker = "camera HAL loaded in bionic helper but did not expose HMI";
      next_step = "verify the vendor HAL export surface and hw_get_module path";
    } else {
      hmi_ok = true;
      write_progress("dlsym:HMI:ok");
      id = module->common.id;
      name = module->common.name;
      author = module->common.author;
      if (options->call_module_entrypoints &&
          module->get_number_of_cameras != NULL) {
        write_progress("module:get-number-of-cameras");
        camera_count = module->get_number_of_cameras();
      }
      if (options->call_module_entrypoints && camera_count > 0 &&
          module->get_camera_info != NULL) {
        camera_info_attempted = true;
        write_progress("module:get-camera-info:0");
        camera_info_status = module->get_camera_info(0, &camera_info);
      }
      module_ok = id != NULL && strcmp(id, "camera") == 0 &&
                  module->common.methods != NULL;
      open_ready = module_ok && module->common.methods->open != NULL;
      if (module_ok) {
        if (options->call_open && open_ready) {
          char progress[160];
          snprintf(progress, sizeof(progress), "module:open:%s",
                   options->camera_id);
          write_progress(progress);
          open_attempted = true;
          open_status = module->common.methods->open(&module->common,
                                                     options->camera_id,
                                                     &opened_device);
          snprintf(progress, sizeof(progress), "module:open:%s:status:%d",
                   options->camera_id, open_status);
          write_progress(progress);
          open_ok = open_status == 0 && opened_device != NULL;
          if (open_ok && opened_device->close != NULL) {
            snprintf(progress, sizeof(progress), "module:close:%s",
                     options->camera_id);
            write_progress(progress);
            close_attempted = true;
            close_status = opened_device->close(opened_device);
            snprintf(progress, sizeof(progress), "module:close:%s:status:%d",
                     options->camera_id, close_status);
            write_progress(progress);
          }
        }
        if (open_ok) {
          blocker_stage = "configure";
          blocker =
              "camera_module_t.open succeeded in bionic helper; camera3 stream "
              "configuration and request submission are not implemented";
          next_step =
              "wire a camera3 configure_streams/process_capture_request shim "
              "with a boot-owned gralloc/native-buffer policy";
        } else {
          blocker_stage = "open";
          if (!open_ready) {
            copy_error(open_blocker_storage, sizeof(open_blocker_storage),
                       "camera_module_t methods.open is unavailable");
          } else if (options->call_open) {
            snprintf(open_blocker_storage, sizeof(open_blocker_storage),
                     "camera_module_t.open returned %d", open_status);
          } else {
            copy_error(open_blocker_storage, sizeof(open_blocker_storage),
                       "open shim not invoked in this boot-safe probe");
          }
          blocker = open_blocker_storage;
          next_step =
              "run the opt-in open/close shim for rear and front camera IDs, "
              "then configure camera3 streams once open succeeds";
        }
      } else {
        blocker_stage = "module";
        blocker = "HMI was found but did not look like a usable camera module";
        next_step =
            "tighten the camera_module_t ABI shim against the vendor module "
            "layout before open/configure/request";
      }
    }
  }

  FILE *out = fopen(options->output, "w");
  if (out == NULL) {
    fprintf(stderr, "pixel_camera_hal_bionic_probe: failed to open %s: %s\n",
            options->output, strerror(errno));
    exit(1);
  }

  fputs("{\n", out);
  fputs("  \"schemaVersion\": 1,\n", out);
  fputs("  \"kind\": \"camera-boot-hal-probe\",\n", out);
  fputs("  \"mode\": \"camera-hal-link-probe\",\n", out);
  fprintf(out, "  \"pid\": %ld,\n", (long)getpid());
  fputs("  \"runToken\": ", out);
  json_string(out, options->run_token);
  fputs(",\n  \"halPath\": ", out);
  json_string(out, kHalPath);
  fputs(",\n  \"cameraId\": ", out);
  json_string(out, options->camera_id);
  fputs(",\n  \"linkerRuntime\": \"bionic-helper\",\n", out);
  fprintf(out,
          "  \"mounts\": {\"dev\": %s, \"proc\": %s, \"sys\": %s, "
          "\"devMount\": ",
          options->mount_dev, options->mount_proc, options->mount_sys);
  json_string(out, options->dev_mount);
  fputs("},\n", out);
  fputs("  \"androidCameraApiUse\": {\"ICameraProvider\": false, "
        "\"cameraserver\": false, \"javaCamera2\": false, "
        "\"rootedAndroidShellCameraApi\": false, "
        "\"rootedAndroidShellRecoveryOnly\": true},\n",
        out);
  fputs("  \"pathStatus\": [\n    ", out);
  write_path_statuses(out);
  fputs("\n  ],\n", out);

  fputs("  \"stages\": [\n    ", out);
  write_stage(out, "link", "start", kHalPath);
  fputs(",\n    ", out);
  if (link_ok) {
    write_stage(out, "link", "ok", "dlopen succeeded in bionic helper");
    fputs(",\n    ", out);
    write_stage(out, "hmi", "start", "dlsym HMI");
    fputs(",\n    ", out);
    if (hmi_ok) {
      write_stage(out, "hmi", "ok", "HMI identified");
      fputs(",\n    ", out);
      write_stage(out, "module", module_ok ? "ok" : "blocked",
                  module_ok ? "camera_module_t prefix readable"
                            : "camera module prefix unusable");
      fputs(",\n    ", out);
      if (module_ok && open_attempted) {
        write_stage(out, "open", open_ok ? "ok" : "blocked",
                    open_ok ? "camera_module_t.open returned a device"
                            : blocker);
      } else {
        write_stage(out, "open", "blocked",
                    module_ok ? "open shim not invoked in this boot-safe probe"
                              : blocker);
      }
    } else {
      write_stage(out, "hmi", "blocked", hmi_error);
      fputs(",\n    ", out);
      write_stage(out, "open", "not-reached", blocker);
    }
  } else {
    write_stage(out, "link", "blocked", link_error);
    fputs(",\n    ", out);
    write_stage(out, "open", "not-reached", blocker);
  }
  fputs(",\n    ", out);
  write_stage(out, "configure", "not-reached", blocker);
  fputs(",\n    ", out);
  write_stage(out, "request", "not-reached", blocker);
  fputs("\n  ],\n", out);

  fprintf(out, "  \"link\": {\"attempted\": true, \"ok\": %s, \"mode\": ",
          link_ok ? "true" : "false");
  json_string(out, link_mode);
  fputs(", ", out);
  fputs("\"handle\": ", out);
  if (handle != NULL) {
    fprintf(out, "\"%p\"", handle);
  } else {
    fputs("null", out);
  }
  fputs(", \"error\": ", out);
  if (link_error != NULL) {
    json_string(out, link_error);
  } else {
    fputs("null", out);
  }
  fputs("},\n", out);

  fprintf(out, "  \"hmi\": {\"attempted\": %s, \"ok\": %s, ",
          link_ok ? "true" : "false", hmi_ok ? "true" : "false");
  fputs("\"address\": ", out);
  if (module != NULL) {
    fprintf(out, "\"%p\"", (void *)module);
  } else {
    fputs("null", out);
  }
  fputs(", \"error\": ", out);
  if (hmi_error != NULL) {
    json_string(out, hmi_error);
  } else {
    fputs("null", out);
  }
  if (hmi_ok) {
    fprintf(out,
            ", \"tag\": %" PRIu32 ", \"moduleApiVersion\": %" PRIu16
            ", \"halApiVersion\": %" PRIu16 ", \"id\": ",
            module->common.tag, module->common.module_api_version,
            module->common.hal_api_version);
    json_string(out, id);
    fputs(", \"name\": ", out);
    json_string(out, name);
    fputs(", \"author\": ", out);
    json_string(out, author);
    fprintf(out, ", \"methods\": \"%p\"", (void *)module->common.methods);
  }
  fputs("},\n", out);

  fprintf(out, "  \"module\": {\"attempted\": %s, \"ok\": %s",
          hmi_ok ? "true" : "false", module_ok ? "true" : "false");
  if (hmi_ok) {
    fputs(", \"id\": ", out);
    json_string(out, id);
    fprintf(out,
            ", \"methodsPresent\": %s, \"moduleEntryPointsCalled\": %s, "
            "\"getNumberOfCamerasPresent\": %s, "
            "\"getCameraInfoPresent\": %s, \"cameraCount\": ",
            module->common.methods != NULL ? "true" : "false",
            options->call_module_entrypoints ? "true" : "false",
            module->get_number_of_cameras != NULL ? "true" : "false",
            module->get_camera_info != NULL ? "true" : "false");
    if (camera_count >= 0) {
      fprintf(out, "%d", camera_count);
    } else {
      fputs("null", out);
    }
    fputs(", \"camera0\": ", out);
    if (camera_info_attempted) {
      fprintf(out,
              "{\"attempted\": true, \"status\": %d, \"facing\": %d, "
              "\"orientation\": %d, \"deviceVersion\": %" PRIu32
              ", \"staticMetadata\": \"%p\", \"resourceCost\": %d, "
              "\"conflictingDevicesLength\": %zu}",
              camera_info_status, camera_info.facing, camera_info.orientation,
              camera_info.device_version,
              camera_info.static_camera_characteristics,
              camera_info.resource_cost, camera_info.conflicting_devices_length);
    } else {
      fprintf(out, "{\"attempted\": false, \"reason\": \"%s\"}",
              options->call_module_entrypoints ? "not reached"
                                                : "module entrypoints disabled");
    }
  } else {
    fputs(", \"cameraCount\": null", out);
  }
  fputs("},\n", out);

  fprintf(out,
          "  \"open\": {\"attempted\": %s, \"ok\": %s, \"ready\": %s, "
          "\"cameraId\": ",
          open_attempted ? "true" : "false", open_ok ? "true" : "false",
          open_ready ? "true" : "false");
  json_string(out, options->camera_id);
  fputs(", \"status\": ", out);
  if (open_attempted) {
    fprintf(out, "%d", open_status);
  } else {
    fputs("null", out);
  }
  fputs(", \"device\": ", out);
  if (opened_device != NULL) {
    fprintf(out, "\"%p\"", (void *)opened_device);
  } else {
    fputs("null", out);
  }
  fprintf(out,
          ", \"closeAttempted\": %s, \"closeStatus\": ",
          close_attempted ? "true" : "false");
  if (close_attempted) {
    fprintf(out, "%d", close_status);
  } else {
    fputs("null", out);
  }
  fprintf(out, ", \"closeOk\": %s, \"blocker\": ",
          close_attempted && close_status == 0 ? "true" : "false");
  json_string(out, module_ok ? blocker : "not reached");
  fputs("},\n", out);
  fputs("  \"configure\": {\"attempted\": false, \"ok\": false, "
        "\"blocker\": \"not reached\"},\n",
        out);
  fputs("  \"request\": {\"attempted\": false, \"ok\": false, "
        "\"blocker\": \"not reached\"},\n",
        out);
  fputs("  \"frameCapture\": {\"attempted\": false, \"captured\": false, "
        "\"artifactPath\": null},\n",
        out);
  fputs("  \"blockerStage\": ", out);
  json_string(out, blocker_stage);
  fputs(",\n  \"blocker\": ", out);
  json_string(out, blocker);
  fputs(",\n  \"nextStep\": ", out);
  json_string(out, next_step);
  fputs("\n}\n", out);
  fclose(out);
}

static bool starts_with(const char *value, const char *prefix) {
  return strncmp(value, prefix, strlen(prefix)) == 0;
}

static const char *classify_progress_stage(const char *last_progress) {
  if (last_progress == NULL || last_progress[0] == '\0') {
    return "link";
  }
  if (starts_with(last_progress, "module:open") ||
      starts_with(last_progress, "module:close")) {
    return "open";
  }
  if (starts_with(last_progress, "module:")) {
    return "module";
  }
  if (starts_with(last_progress, "dlsym:HMI")) {
    return "hmi";
  }
  return "link";
}

static void write_child_failure_summary(const options_t *options, int wait_status) {
  FILE *out = fopen(options->output, "w");
  if (out == NULL) {
    fprintf(stderr, "pixel_camera_hal_bionic_probe: failed to open %s: %s\n",
            options->output, strerror(errno));
    exit(1);
  }

  char detail[160];
  char last_progress[256];
  read_progress(options->progress_output, last_progress, sizeof(last_progress));
  const char *failure_stage = classify_progress_stage(last_progress);
  bool link_reached = strcmp(failure_stage, "link") != 0;
  bool hmi_reached = strcmp(failure_stage, "module") == 0 ||
                     strcmp(failure_stage, "open") == 0;
  bool module_reached = strcmp(failure_stage, "open") == 0;
  if (WIFSIGNALED(wait_status)) {
    snprintf(detail, sizeof(detail),
             "bionic helper child terminated by signal %d during HAL probe",
             WTERMSIG(wait_status));
  } else if (WIFEXITED(wait_status)) {
    snprintf(detail, sizeof(detail),
             "bionic helper child exited %d before writing probe summary",
             WEXITSTATUS(wait_status));
  } else {
    snprintf(detail, sizeof(detail),
             "bionic helper child ended with wait status %d", wait_status);
  }

  fputs("{\n", out);
  fputs("  \"schemaVersion\": 1,\n", out);
  fputs("  \"kind\": \"camera-boot-hal-probe\",\n", out);
  fputs("  \"mode\": \"camera-hal-link-probe\",\n", out);
  fprintf(out, "  \"pid\": %ld,\n", (long)getpid());
  fputs("  \"runToken\": ", out);
  json_string(out, options->run_token);
  fputs(",\n  \"halPath\": ", out);
  json_string(out, kHalPath);
  fputs(",\n  \"cameraId\": ", out);
  json_string(out, options->camera_id);
  fputs(",\n  \"linkerRuntime\": \"bionic-helper\",\n", out);
  fprintf(out,
          "  \"mounts\": {\"dev\": %s, \"proc\": %s, \"sys\": %s, "
          "\"devMount\": ",
          options->mount_dev, options->mount_proc, options->mount_sys);
  json_string(out, options->dev_mount);
  fputs("},\n", out);
  fputs("  \"androidCameraApiUse\": {\"ICameraProvider\": false, "
        "\"cameraserver\": false, \"javaCamera2\": false, "
        "\"rootedAndroidShellCameraApi\": false, "
        "\"rootedAndroidShellRecoveryOnly\": true},\n",
        out);
  fputs("  \"pathStatus\": [\n    ", out);
  write_path_statuses(out);
  fputs("\n  ],\n", out);
  fputs("  \"stages\": [\n    ", out);
  write_stage(out, "link", "start", kHalPath);
  fputs(",\n    ", out);
  write_stage(out, "link", link_reached ? "ok" : "blocked",
              link_reached ? "dlopen succeeded before child failure" : detail);
  fputs(",\n    ", out);
  write_stage(out, "hmi", hmi_reached ? "ok" : "not-reached",
              hmi_reached ? "HMI resolved before child failure" : detail);
  fputs(",\n    ", out);
  write_stage(out, "module", module_reached ? "ok" : "not-reached",
              module_reached ? "camera_module_t prefix reached before child failure"
                             : detail);
  fputs(",\n    ", out);
  write_stage(out, "open", strcmp(failure_stage, "open") == 0 ? "blocked"
                                                               : "not-reached",
              detail);
  fputs(",\n    ", out);
  write_stage(out, "configure", "not-reached", detail);
  fputs(",\n    ", out);
  write_stage(out, "request", "not-reached", detail);
  fputs("\n  ],\n", out);
  fprintf(out, "  \"link\": {\"attempted\": true, \"ok\": %s, "
               "\"handle\": null, \"error\": ",
          link_reached ? "true" : "false");
  if (link_reached) {
    fputs("null", out);
  } else {
    json_string(out, detail);
  }
  fputs(", \"lastProgress\": ", out);
  json_string(out, last_progress);
  fputs("},\n", out);
  fprintf(out,
          "  \"hmi\": {\"attempted\": %s, \"ok\": %s, "
          "\"address\": null, \"error\": null},\n",
          link_reached ? "true" : "false", hmi_reached ? "true" : "false");
  fprintf(out,
          "  \"module\": {\"attempted\": %s, \"ok\": %s, "
          "\"cameraCount\": null},\n",
          hmi_reached ? "true" : "false", module_reached ? "true" : "false");
  fprintf(out,
          "  \"open\": {\"attempted\": %s, \"ok\": false, "
          "\"ready\": false, \"cameraId\": ",
          strcmp(failure_stage, "open") == 0 ? "true" : "false");
  json_string(out, options->camera_id);
  fputs(", \"blocker\": ", out);
  if (strcmp(failure_stage, "open") == 0) {
    json_string(out, detail);
  } else {
    json_string(out, "not reached");
  }
  fputs("},\n", out);
  fputs("  \"configure\": {\"attempted\": false, \"ok\": false, "
        "\"blocker\": \"not reached\"},\n",
        out);
  fputs("  \"request\": {\"attempted\": false, \"ok\": false, "
        "\"blocker\": \"not reached\"},\n",
        out);
  fputs("  \"frameCapture\": {\"attempted\": false, \"captured\": false, "
        "\"artifactPath\": null},\n",
        out);
  fputs("  \"blockerStage\": ", out);
  json_string(out, failure_stage);
  fputs(",\n", out);
  fputs("  \"blocker\": ", out);
  json_string(out, detail);
  fputs(",\n  \"lastProgress\": ", out);
  json_string(out, last_progress);
  if (strcmp(failure_stage, "open") == 0) {
    fputs(",\n  \"nextStep\": \"instrument camera_module_t.open with CamX/KMD "
          "device-node and thread-state evidence, then add the minimal missing "
          "boot services or kernel interfaces needed for open to return\"\n",
          out);
  } else {
    fputs(",\n  \"nextStep\": \"isolate the bionic/vendor HAL abort with "
          "linker namespace, property, and vendor dependency logging before "
          "camera_module_t.open\"\n",
          out);
  }
  fputs("}\n", out);
  fclose(out);
}

int main(int argc, char **argv) {
  (void)kProbeSentinel;
  options_t options = parse_options(argc, argv);

  char child_output[4096];
  char child_progress[4096];
  snprintf(child_output, sizeof(child_output), "%s.child", options.output);
  snprintf(child_progress, sizeof(child_progress), "%s.progress", options.output);
  options.progress_output = child_progress;
  unlink(child_output);
  unlink(child_progress);

  pid_t child = fork();
  if (child == 0) {
    options.output = child_output;
    options.progress_output = child_progress;
    write_summary(&options);
    _exit(0);
  }
  if (child < 0) {
    write_summary(&options);
    return 0;
  }

  int wait_status = 0;
  uint32_t waited_secs = 0;
  for (;;) {
    pid_t wait_result = waitpid(child, &wait_status, WNOHANG);
    if (wait_result == child) {
      break;
    }
    if (wait_result < 0) {
      fprintf(stderr, "pixel_camera_hal_bionic_probe: waitpid failed: %s\n",
              strerror(errno));
      write_child_failure_summary(&options, 1 << 8);
      return 0;
    }
    if (options.child_timeout_secs > 0 &&
        waited_secs >= options.child_timeout_secs) {
      kill(child, SIGKILL);
      if (waitpid(child, &wait_status, 0) < 0) {
        wait_status = SIGKILL;
      }
      write_child_failure_summary(&options, wait_status);
      return 0;
    }
    sleep(1);
    waited_secs++;
  }

  if (WIFEXITED(wait_status) && WEXITSTATUS(wait_status) == 0 &&
      access(child_output, R_OK) == 0) {
    if (rename(child_output, options.output) != 0) {
      fprintf(stderr, "pixel_camera_hal_bionic_probe: rename %s -> %s failed: %s\n",
              child_output, options.output, strerror(errno));
      write_child_failure_summary(&options, 1 << 8);
    }
    return 0;
  }

  write_child_failure_summary(&options, wait_status);
  return 0;
}
