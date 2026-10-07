#include <stdint.h>

typedef int32_t(__cdecl *RgbctrlNvmlThunk)(void *context);

unsigned long __cdecl _exception_code(void);

static int32_t rgbctrl_nvml_exception_filter(uint32_t code, uint32_t *exception_code)
{
    if (code != UINT32_C(0xC0000005)) {
        return 0;
    }
    *exception_code = code;
    return 1;
}

int32_t rgbctrl_nvml_guard(
    RgbctrlNvmlThunk thunk,
    void *context,
    int32_t *status,
    uint32_t *exception_code)
{
    *exception_code = 0;
    __try {
        *status = thunk(context);
        return 1;
    } __except (rgbctrl_nvml_exception_filter((uint32_t)_exception_code(), exception_code)) {
        return 0;
    }
}

#ifdef RGBCTRL_NVML_GUARD_TEST
__declspec(dllimport) void __stdcall RaiseException(
    unsigned long exception_code,
    unsigned long exception_flags,
    unsigned long argument_count,
    const uintptr_t *arguments);

int32_t rgbctrl_nvml_test_value(void *device, uint32_t kind, uint32_t *value)
{
    (void)device;
    (void)kind;
    *value = 1455;
    return 3;
}

int32_t rgbctrl_nvml_test_access_violation(void *device, uint32_t kind, uint32_t *value)
{
    volatile uint32_t *invalid = (volatile uint32_t *)(uintptr_t)0x10;
    (void)device;
    (void)kind;
    *value = *invalid;
    return 0;
}

static int32_t rgbctrl_nvml_test_raise_exception(void *context)
{
    (void)context;
    RaiseException(UINT32_C(0xE0001234), 0, 0, 0);
    return 0;
}

int32_t rgbctrl_nvml_test_continue_search(uint32_t *exception_code)
{
    int32_t status = 0;
    uint32_t inner_exception_code = 0;
    *exception_code = 0;
    __try {
        (void)rgbctrl_nvml_guard(
            rgbctrl_nvml_test_raise_exception,
            0,
            &status,
            &inner_exception_code);
        return 0;
    } __except ((*exception_code = (uint32_t)_exception_code(), 1)) {
        return 1;
    }
}
#endif
