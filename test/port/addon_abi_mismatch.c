#include "addon.h"

int js_register_modules(JsRegistry *registry) {
    return registry->api->abi_version == JS_ADDON_ABI_VERSION ? -1 : 0;
}
