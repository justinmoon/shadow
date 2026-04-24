#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SHADOW_PROP_NAME_MAX 64
#define SHADOW_PROP_VALUE_MAX 128

__attribute__((used)) static const char shadow_property_shim_sentinel[] =
    "shadow-property-shim";

struct prop_info {
  char name[SHADOW_PROP_NAME_MAX];
  char value[SHADOW_PROP_VALUE_MAX];
};

static struct prop_info shadow_prop;

typedef int (*system_property_get_fn)(const char *name, char *value);
typedef const struct prop_info *(*system_property_find_fn)(const char *name);
typedef int (*system_property_read_fn)(const struct prop_info *pi, char *name,
                                       char *value);
typedef void (*system_property_read_callback_fn)(
    const struct prop_info *pi,
    void (*callback)(void *cookie, const char *name, const char *value,
                     uint32_t serial),
    void *cookie);
typedef int (*property_get_fn)(const char *key, char *value,
                               const char *default_value);
typedef int (*property_set_fn)(const char *key, const char *value);
typedef int (*service_manager_add_service_fn)(void *binder,
                                              const char *instance);

static const char *shadow_property_value(const char *name) {
  if (!name) {
    return NULL;
  }
  if (!strcmp(name, "ro.baseband") || !strcmp(name, "ro.boot.baseband")) {
    return "msm";
  }
  if (!strcmp(name, "ro.board.platform")) {
    return "sm6150";
  }
  if (!strcmp(name, "ro.boot.hardware") || !strcmp(name, "ro.hardware")) {
    return "sunfish";
  }
  if (!strcmp(name, "ro.boot.hardware.platform")) {
    return "sm7150";
  }
  if (!strcmp(name, "ro.boot.hardware.radio.subtype") ||
      !strcmp(name, "persist.radio.multisim.config")) {
    return "";
  }
  if (!strcmp(name, "ro.boot.hardware.dsds")) {
    return "0";
  }
  if (!strcmp(name, "telephony.active_modems.max_count")) {
    return "2";
  }
  if (!strcmp(name, "ro.property_service.version")) {
    return "2";
  }
  return NULL;
}

static void *shadow_next_symbol(const char *name) {
  return dlsym(RTLD_NEXT, name);
}

static int shadow_copy_property_value(char *value, const char *prop) {
  if (value) {
    strcpy(value, prop);
  }
  return (int)strlen(prop);
}

int __system_property_get(const char *name, char *value) {
  const char *prop = shadow_property_value(name);
  if (!prop) {
    system_property_get_fn real_get =
        (system_property_get_fn)shadow_next_symbol("__system_property_get");
    if (real_get) {
      return real_get(name, value);
    }
    if (value) {
      value[0] = '\0';
    }
    return 0;
  }
  return shadow_copy_property_value(value, prop);
}

const struct prop_info *__system_property_find(const char *name) {
  const char *prop = shadow_property_value(name);
  if (!prop) {
    system_property_find_fn real_find =
        (system_property_find_fn)shadow_next_symbol("__system_property_find");
    if (real_find) {
      return real_find(name);
    }
    return NULL;
  }
  strncpy(shadow_prop.name, name, sizeof(shadow_prop.name) - 1);
  shadow_prop.name[sizeof(shadow_prop.name) - 1] = '\0';
  strncpy(shadow_prop.value, prop, sizeof(shadow_prop.value) - 1);
  shadow_prop.value[sizeof(shadow_prop.value) - 1] = '\0';
  return &shadow_prop;
}

int __system_property_read(const struct prop_info *pi, char *name, char *value) {
  if (!pi) {
    return 0;
  }
  if (pi != &shadow_prop) {
    system_property_read_fn real_read =
        (system_property_read_fn)shadow_next_symbol("__system_property_read");
    if (real_read) {
      return real_read(pi, name, value);
    }
    return 0;
  }
  if (name) {
    strcpy(name, pi->name);
  }
  return shadow_copy_property_value(value, pi->value);
}

void __system_property_read_callback(
    const struct prop_info *pi,
    void (*callback)(void *cookie, const char *name, const char *value,
                     uint32_t serial),
    void *cookie) {
  if (pi == &shadow_prop && callback) {
    callback(cookie, pi->name, pi->value, 0);
    return;
  }
  system_property_read_callback_fn real_callback =
      (system_property_read_callback_fn)shadow_next_symbol(
          "__system_property_read_callback");
  if (real_callback) {
    real_callback(pi, callback, cookie);
  }
}

int property_get(const char *key, char *value, const char *default_value) {
  const char *prop = shadow_property_value(key);
  if (prop) {
    return shadow_copy_property_value(value, prop);
  }

  property_get_fn real_get = (property_get_fn)shadow_next_symbol("property_get");
  if (real_get) {
    return real_get(key, value, default_value);
  }

  prop = default_value;
  if (!prop) {
    if (value) {
      value[0] = '\0';
    }
    return 0;
  }
  return shadow_copy_property_value(value, prop);
}

int property_set(const char *key, const char *value) {
  property_set_fn real_set = (property_set_fn)shadow_next_symbol("property_set");
  if (real_set) {
    return real_set(key, value);
  }
  return 0;
}

int AServiceManager_addService(void *binder, const char *instance) {
  const char *allow_fake =
      getenv("SHADOW_FAKE_WIFI_SUPPLICANT_SERVICE_REGISTRATION");
  if (instance &&
      allow_fake && !strcmp(allow_fake, "1") &&
      !strcmp(instance, "android.hardware.wifi.supplicant.ISupplicant/default")) {
    fprintf(stderr, "shadow-service-shim: faking addService for %s\n", instance);
    return 0;
  }

  service_manager_add_service_fn real_add =
      (service_manager_add_service_fn)shadow_next_symbol(
          "AServiceManager_addService");
  if (real_add) {
    return real_add(binder, instance);
  }
  return -1;
}

int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
  (void)prio;
  va_list ap;
  fprintf(stderr, "%s: ", tag ? tag : "android-log");
  va_start(ap, fmt);
  vfprintf(stderr, fmt ? fmt : "", ap);
  va_end(ap);
  fputc('\n', stderr);
  return 1;
}

int __android_log_vprint(int prio, const char *tag, const char *fmt,
                         va_list ap) {
  (void)prio;
  fprintf(stderr, "%s: ", tag ? tag : "android-log");
  vfprintf(stderr, fmt ? fmt : "", ap);
  fputc('\n', stderr);
  return 1;
}

int __android_log_buf_print(int buf_id, int prio, const char *tag,
                            const char *fmt, ...) {
  (void)buf_id;
  (void)prio;
  va_list ap;
  fprintf(stderr, "%s: ", tag ? tag : "android-log");
  va_start(ap, fmt);
  vfprintf(stderr, fmt ? fmt : "", ap);
  va_end(ap);
  fputc('\n', stderr);
  return 1;
}

int __android_log_buf_write(int buf_id, int prio, const char *tag,
                            const char *text) {
  (void)buf_id;
  (void)prio;
  fprintf(stderr, "%s: %s\n", tag ? tag : "android-log", text ? text : "");
  return 1;
}

int __android_log_write(int prio, const char *tag, const char *text) {
  (void)prio;
  fprintf(stderr, "%s: %s\n", tag ? tag : "android-log", text ? text : "");
  return 1;
}
