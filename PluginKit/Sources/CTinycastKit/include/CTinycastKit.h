// The host functions a Tinycast plugin imports, module "tinycast". Strings cross as UTF-8 bytes in
// the plugin's memory, JSON where they carry structure.
#include <stddef.h>
#include <stdint.h>

#define TINYCAST_IMPORT(name) __attribute__((import_module("tinycast"), import_name(#name)))

/// The command's screens, as Raycast's renderer draws them.
TINYCAST_IMPORT(render) void tinycast_render(uint32_t session, const uint8_t *json, size_t length);
TINYCAST_IMPORT(navigation) void tinycast_navigation(uint32_t session, uint32_t depth);
TINYCAST_IMPORT(finished) void tinycast_finished(uint32_t session);
TINYCAST_IMPORT(failed) void tinycast_failed(uint32_t session, const uint8_t *message, size_t length);
/// `{"api","method","args"}`; answered later through the `tinycast_settle` export.
TINYCAST_IMPORT(call) void tinycast_call(uint32_t id, const uint8_t *json, size_t length);
/// Answered through the `tinycast_timer` export.
TINYCAST_IMPORT(set_timer) void tinycast_set_timer(uint32_t token, double milliseconds);
TINYCAST_IMPORT(clear_timer) void tinycast_clear_timer(uint32_t token);
TINYCAST_IMPORT(manifest) void tinycast_manifest(const uint8_t *json, size_t length);

/// The plugin's entry point, which SwiftPM's executable target names this on WebAssembly.
int __main_argc_argv(int argc, char **argv);
static inline void tinycast_run_main(void) { __main_argc_argv(0, 0); }
