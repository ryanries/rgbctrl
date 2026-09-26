#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RGBCTRL_ABI_VERSION 1u
#define RGBCTRL_PLUGIN_ENTRY_NAME "rgbctrl_plugin_entry"

#define RGBCTRL_OK             0
#define RGBCTRL_E_FAIL        (-1)
#define RGBCTRL_E_UNSUPPORTED (-2)
#define RGBCTRL_E_ARGUMENT    (-3)
#define RGBCTRL_E_DEVICE_LOST (-4)
#define RGBCTRL_E_ACCESS      (-5)
#define RGBCTRL_E_BUSY        (-6)
#define RGBCTRL_RESCAN_CHANGED 1

#define RGBCTRL_LOG_ERROR 0u
#define RGBCTRL_LOG_WARN  1u
#define RGBCTRL_LOG_INFO  2u
#define RGBCTRL_LOG_DEBUG 3u
#define RGBCTRL_LOG_TRACE 4u

#define RGBCTRL_EFFECT_OFF       0u
#define RGBCTRL_EFFECT_STATIC    1u
#define RGBCTRL_EFFECT_BREATHING 2u
#define RGBCTRL_EFFECT_FLASH     3u
#define RGBCTRL_EFFECT_CYCLE     4u
#define RGBCTRL_EFFECT_RAINBOW   5u
#define RGBCTRL_EFFECT_GRADIENT  6u
#define RGBCTRL_EFFECT_BIT(effect) (1u << (effect))

#define RGBCTRL_ZONE_RESIZABLE              0x1u
#define RGBCTRL_ZONE_GLOBAL_BRIGHTNESS_ONLY 0x2u
#define RGBCTRL_ZONE_HOST_FRAMES            0x4u

#define RGBCTRL_PLUGIN_OPT_IN        0x1u
#define RGBCTRL_PLUGIN_SENSOR_SOURCE 0x2u

#define RGBCTRL_TRANSPORT_HID   0x1u
#define RGBCTRL_TRANSPORT_SMBUS 0x2u
#define RGBCTRL_TRANSPORT_I2C   0x4u
#define RGBCTRL_TRANSPORT_OS    0x8u

#define RGBCTRL_MODE_RUN   1u
#define RGBCTRL_MODE_APPLY 2u
#define RGBCTRL_MODE_LIST  3u

#define RGBCTRL_CLOSE_KEEP 0u
#define RGBCTRL_CLOSE_EXIT 1u

#define RGBCTRL_RESCAN_HOTPLUG 1u
#define RGBCTRL_RESCAN_RESUME  2u
#define RGBCTRL_RESCAN_RECOVER 3u

#define RGBCTRL_JSON_NONE   0u
#define RGBCTRL_JSON_NULL   1u
#define RGBCTRL_JSON_BOOL   2u
#define RGBCTRL_JSON_NUMBER 3u
#define RGBCTRL_JSON_STRING 4u
#define RGBCTRL_JSON_ARRAY  5u
#define RGBCTRL_JSON_OBJECT 6u

typedef struct rgbctrl_rgb
{
    uint8_t r;
    uint8_t g;
    uint8_t b;
} rgbctrl_rgb;

typedef struct rgbctrl_json rgbctrl_json;

typedef struct rgbctrl_host
{
    uint32_t struct_size;
    uint32_t abi_version;
    void *ctx;
    const uint16_t *host_dir;
    uint32_t mode;
    uint32_t reserved;
    void (*log)(void *ctx, uint32_t level, const char *msg, size_t msg_len);
    uint64_t (*now_ms)(void *ctx);
    void (*sensor_set)(void *ctx, const char *name, size_t name_len, double value);
    int32_t (*sensor_get)(void *ctx, const char *name, size_t name_len, double *value, uint64_t *age_ms);
    uint32_t (*json_type)(void *ctx, const rgbctrl_json *node);
    const rgbctrl_json *(*json_get)(void *ctx, const rgbctrl_json *object, const char *key, size_t key_len);
    uint32_t (*json_len)(void *ctx, const rgbctrl_json *node);
    const rgbctrl_json *(*json_at)(void *ctx, const rgbctrl_json *array, uint32_t index);
    const rgbctrl_json *(*json_member)(void *ctx, const rgbctrl_json *object, uint32_t index, const char **key, size_t *key_len);
    int32_t (*json_number)(void *ctx, const rgbctrl_json *node, double *value);
    int32_t (*json_bool)(void *ctx, const rgbctrl_json *node, int32_t *value);
    int32_t (*json_string)(void *ctx, const rgbctrl_json *node, const char **text, size_t *text_len);
} rgbctrl_host;

typedef struct rgbctrl_zone_info
{
    uint32_t struct_size;
    uint32_t flags;
    const char *name;
    uint32_t led_count;
    uint32_t max_leds;
    uint32_t hw_effects;
    uint32_t hw_max_colors;
    const uint16_t *led_x;
} rgbctrl_zone_info;

typedef struct rgbctrl_device_info
{
    uint32_t struct_size;
    uint32_t zone_count;
    const char *id;
    const char *name;
    const rgbctrl_zone_info *const *zones;
    uint32_t max_fps;
    uint32_t reserved;
} rgbctrl_device_info;

typedef struct rgbctrl_hw_effect
{
    uint32_t struct_size;
    uint32_t effect;
    uint32_t speed;
    uint32_t brightness;
    uint32_t color_count;
    uint32_t reserved;
    const rgbctrl_rgb *colors;
} rgbctrl_hw_effect;

typedef struct rgbctrl_plugin
{
    uint32_t struct_size;
    uint32_t abi_version;
    const char *name;
    const char *version;
    uint32_t flags;
    uint32_t tick_interval_ms;
    uint32_t transports;
    uint32_t reserved;
    int32_t (*open)(const rgbctrl_host *host, const rgbctrl_json *config, void **instance);
    void (*close)(void *instance, uint32_t reason);
    uint32_t (*device_count)(void *instance);
    const rgbctrl_device_info *(*device_info)(void *instance, uint32_t device_index);
    int32_t (*set_zone_size)(void *instance, uint32_t device_index, uint32_t zone_index, uint32_t led_count);
    int32_t (*set_hw_effect)(void *instance, uint32_t device_index, uint32_t zone_index, const rgbctrl_hw_effect *effect);
    int32_t (*set_leds)(void *instance, uint32_t device_index, uint32_t zone_index, const rgbctrl_rgb *colors, uint32_t count);
    int32_t (*flush)(void *instance, uint32_t device_index);
    int32_t (*tick)(void *instance, uint64_t now_ms);
    int32_t (*rescan)(void *instance, uint32_t reason);
    int32_t (*persist)(void *instance, uint32_t device_index);
} rgbctrl_plugin;

typedef const rgbctrl_plugin *(*rgbctrl_plugin_entry_fn)(uint32_t host_abi_version);

#ifdef __cplusplus
}
#endif
