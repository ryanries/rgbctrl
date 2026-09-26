#include <stddef.h>
#include <stdint.h>
#include "rgbctrl_plugin.h"

#define VIRTUAL_DEFAULT_LEDS 16u
#define VIRTUAL_MAX_LEDS 64u

typedef struct virtual_state {
    const rgbctrl_host *host;
    uint32_t stall_ms;
    uint32_t lose_after_frames;
    uint32_t frames;
    int bad_device;
    int extra_device;
    int hardware_only;
    int lost;
    uint32_t device_total;
    rgbctrl_zone_info strip;
    const rgbctrl_zone_info *strip_zones[1];
    rgbctrl_zone_info extra_strip;
    const rgbctrl_zone_info *extra_zones[1];
    rgbctrl_device_info devices[3];
    const rgbctrl_device_info *order[3];
    rgbctrl_rgb leds[VIRTUAL_MAX_LEDS];
} virtual_state;

static virtual_state state;

static size_t text_length(const char *text) {
    size_t length = 0;
    while (text[length] != '\0') {
        length++;
    }
    return length;
}

static void log_text(uint32_t level, const char *text) {
    state.host->log(state.host->ctx, level, text, text_length(text));
}

static void log_number(uint32_t level, const char *prefix, uint64_t value) {
    char buffer[96];
    size_t length = 0;
    while (prefix[length] != '\0' && length < 64) {
        buffer[length] = prefix[length];
        length++;
    }
    char digits[20];
    size_t count = 0;
    do {
        digits[count++] = (char)('0' + (value % 10u));
        value /= 10u;
    } while (value != 0 && count < sizeof digits);
    while (count > 0) {
        buffer[length++] = digits[--count];
    }
    state.host->log(state.host->ctx, level, buffer, length);
}

static uint32_t config_number(const rgbctrl_json *config, const char *key, uint32_t fallback) {
    const rgbctrl_json *node = state.host->json_get(state.host->ctx, config, key, text_length(key));
    double value = 0.0;
    if (node == NULL || state.host->json_number(state.host->ctx, node, &value) != RGBCTRL_OK) {
        return fallback;
    }
    if (value < 0.0) {
        return 0;
    }
    if (value > 600000.0) {
        return 600000u;
    }
    return (uint32_t)(value + 0.5);
}

static int config_flag(const rgbctrl_json *config, const char *key) {
    const rgbctrl_json *node = state.host->json_get(state.host->ctx, config, key, text_length(key));
    int32_t value = 0;
    if (node == NULL || state.host->json_bool(state.host->ctx, node, &value) != RGBCTRL_OK) {
        return 0;
    }
    return value != 0;
}

static void busy_wait(uint32_t milliseconds) {
    uint64_t start = state.host->now_ms(state.host->ctx);
    while (state.host->now_ms(state.host->ctx) - start < milliseconds) {
    }
}

static void describe_zone(rgbctrl_zone_info *zone, const char *name) {
    zone->struct_size = sizeof *zone;
    zone->flags = state.hardware_only ? 0u : (RGBCTRL_ZONE_RESIZABLE | RGBCTRL_ZONE_HOST_FRAMES);
    zone->name = name;
    zone->led_count = VIRTUAL_DEFAULT_LEDS;
    zone->max_leds = VIRTUAL_MAX_LEDS;
    zone->hw_effects = RGBCTRL_EFFECT_BIT(RGBCTRL_EFFECT_OFF) | RGBCTRL_EFFECT_BIT(RGBCTRL_EFFECT_STATIC);
    zone->hw_max_colors = 1;
    zone->led_x = NULL;
}

static void describe_devices(void) {
    uint32_t index = 0;
    describe_zone(&state.strip, "strip");
    state.strip_zones[0] = &state.strip;
    state.devices[index].struct_size = sizeof state.devices[index];
    state.devices[index].zone_count = 1;
    state.devices[index].id = "virtual";
    state.devices[index].name = "Virtual LED strip";
    state.devices[index].zones = state.strip_zones;
    state.devices[index].max_fps = 0;
    state.devices[index].reserved = 0;
    index++;
    if (state.bad_device) {
        state.devices[index].struct_size = sizeof state.devices[index];
        state.devices[index].zone_count = 1;
        state.devices[index].id = "Bad Id";
        state.devices[index].name = "Invalid device";
        state.devices[index].zones = NULL;
        state.devices[index].max_fps = 0;
        state.devices[index].reserved = 0;
        index++;
    }
    if (state.extra_device) {
        describe_zone(&state.extra_strip, "strip");
        state.extra_zones[0] = &state.extra_strip;
        state.devices[index].struct_size = sizeof state.devices[index];
        state.devices[index].zone_count = 1;
        state.devices[index].id = "virtual2";
        state.devices[index].name = "Second virtual LED strip";
        state.devices[index].zones = state.extra_zones;
        state.devices[index].max_fps = 10;
        state.devices[index].reserved = 0;
        index++;
    }
    state.device_total = index;
}

static int32_t virtual_open(const rgbctrl_host *host, const rgbctrl_json *config, void **instance) {
    state.host = host;
    uint32_t stall_open_ms = config_number(config, "stall_open_ms", 0);
    state.stall_ms = config_number(config, "stall_ms", 0);
    state.lose_after_frames = config_number(config, "lose_after_frames", 0);
    state.bad_device = config_flag(config, "bad_device");
    state.extra_device = config_flag(config, "extra_device");
    state.hardware_only = config_flag(config, "hardware_only");
    state.frames = 0;
    state.lost = 0;
    if (stall_open_ms > 0) {
        busy_wait(stall_open_ms);
    }
    if (config_flag(config, "fail_open")) {
        log_text(RGBCTRL_LOG_ERROR, "fail_open is set; refusing to open");
        return RGBCTRL_E_FAIL;
    }
    describe_devices();
    log_text(RGBCTRL_LOG_INFO, "virtual device ready");
    *instance = &state;
    return RGBCTRL_OK;
}

static void virtual_close(void *instance, uint32_t reason) {
    (void)instance;
    log_text(RGBCTRL_LOG_INFO, reason == RGBCTRL_CLOSE_EXIT ? "closed (exit)" : "closed (keep)");
}

static uint32_t virtual_device_count(void *instance) {
    (void)instance;
    return state.lost ? 0u : state.device_total;
}

static const rgbctrl_device_info *virtual_device_info(void *instance, uint32_t device_index) {
    (void)instance;
    if (device_index >= state.device_total) {
        return NULL;
    }
    return &state.devices[device_index];
}

static rgbctrl_zone_info *zone_for(uint32_t device_index, uint32_t zone_index) {
    if (zone_index != 0 || device_index >= state.device_total) {
        return NULL;
    }
    if (device_index == 0) {
        return &state.strip;
    }
    if (state.extra_device && device_index == state.device_total - 1) {
        return &state.extra_strip;
    }
    return NULL;
}

static int32_t virtual_set_zone_size(void *instance, uint32_t device_index, uint32_t zone_index, uint32_t led_count) {
    (void)instance;
    rgbctrl_zone_info *zone = zone_for(device_index, zone_index);
    if (zone == NULL || led_count > VIRTUAL_MAX_LEDS) {
        return RGBCTRL_E_ARGUMENT;
    }
    zone->led_count = led_count;
    log_number(RGBCTRL_LOG_INFO, "zone resized to ", led_count);
    return RGBCTRL_OK;
}

static int32_t virtual_set_hw_effect(void *instance, uint32_t device_index, uint32_t zone_index, const rgbctrl_hw_effect *effect) {
    (void)instance;
    if (zone_for(device_index, zone_index) == NULL || effect == NULL) {
        return RGBCTRL_E_ARGUMENT;
    }
    if (effect->effect != RGBCTRL_EFFECT_OFF && effect->effect != RGBCTRL_EFFECT_STATIC) {
        return RGBCTRL_E_UNSUPPORTED;
    }
    log_number(RGBCTRL_LOG_INFO, "hardware effect ", effect->effect);
    return RGBCTRL_OK;
}

static int32_t virtual_set_leds(void *instance, uint32_t device_index, uint32_t zone_index, const rgbctrl_rgb *colors, uint32_t count) {
    (void)instance;
    rgbctrl_zone_info *zone = zone_for(device_index, zone_index);
    if (zone == NULL || colors == NULL || count > zone->led_count) {
        return RGBCTRL_E_ARGUMENT;
    }
    for (uint32_t index = 0; index < count; index++) {
        state.leds[index] = colors[index];
    }
    return RGBCTRL_OK;
}

static int32_t virtual_flush(void *instance, uint32_t device_index) {
    (void)instance;
    (void)device_index;
    if (state.lost) {
        return RGBCTRL_E_DEVICE_LOST;
    }
    if (state.stall_ms > 0) {
        busy_wait(state.stall_ms);
    }
    state.frames++;
    if (state.lose_after_frames > 0 && state.frames >= state.lose_after_frames) {
        state.lost = 1;
        log_text(RGBCTRL_LOG_WARN, "simulating a lost device");
        return RGBCTRL_E_DEVICE_LOST;
    }
    log_number(RGBCTRL_LOG_TRACE, "frame with first LED red = ", state.leds[0].r);
    return RGBCTRL_OK;
}

static int32_t virtual_tick(void *instance, uint64_t now_ms) {
    (void)instance;
    (void)now_ms;
    state.host->sensor_set(state.host->ctx, "virtual_led.frames", 18, (double)state.frames);
    return RGBCTRL_OK;
}

static int32_t virtual_rescan(void *instance, uint32_t reason) {
    (void)instance;
    if (reason == RGBCTRL_RESCAN_RECOVER && state.lost) {
        state.lost = 0;
        state.frames = 0;
        state.lose_after_frames = 0;
        log_text(RGBCTRL_LOG_INFO, "recovered");
        return RGBCTRL_RESCAN_CHANGED;
    }
    return RGBCTRL_OK;
}

static int32_t virtual_persist(void *instance, uint32_t device_index) {
    (void)instance;
    log_number(RGBCTRL_LOG_INFO, "persist called for device ", device_index);
    return RGBCTRL_OK;
}

static const rgbctrl_plugin plugin = {
#if defined(RGBCTRL_TEST_SHORT_STRUCT)
    64u,
#else
    sizeof(rgbctrl_plugin),
#endif
#if defined(RGBCTRL_TEST_ABI0)
    0u,
#elif defined(RGBCTRL_TEST_ABI2)
    2u,
#else
    RGBCTRL_ABI_VERSION,
#endif
    "virtual_led",
    "1.0.0",
    0u,
    1000u,
    0u,
    0u,
    virtual_open,
    virtual_close,
    virtual_device_count,
    virtual_device_info,
    virtual_set_zone_size,
    virtual_set_hw_effect,
    virtual_set_leds,
    virtual_flush,
    virtual_tick,
    virtual_rescan,
    virtual_persist,
};

__declspec(dllexport) const rgbctrl_plugin *rgbctrl_plugin_entry(uint32_t host_abi_version) {
#if defined(RGBCTRL_TEST_NULL_ENTRY)
    (void)host_abi_version;
    (void)plugin;
    return NULL;
#else
    if (host_abi_version < 1u) {
        return NULL;
    }
    return &plugin;
#endif
}
