/* Minimal synchronous Pulse API fixture for the actual pamixer executable.
 * A rejected mute callback leaves the sink muted without changing pamixer's
 * exit status. No audio server is contacted or modified. */
#include <pulse/pulseaudio.h>
#include <stdlib.h>

static pa_mainloop_api api;
static pa_cvolume volumes;
static int muted = 1;
static int initialized;
static pa_context_notify_cb_t state_callback;
static void *state_data;

static void setup(void) {
  if (initialized) return;
  initialized = 1;
  pa_cvolume_set(&volumes, 2, PA_VOLUME_NORM / 2);
}

pa_mainloop *pa_mainloop_new(void) { return (pa_mainloop *)1; }
pa_mainloop_api *pa_mainloop_get_api(pa_mainloop *m) { return &api; }
void pa_mainloop_free(pa_mainloop *m) {}
int pa_mainloop_iterate(pa_mainloop *m, int block, int *retval) { return 0; }
pa_context *pa_context_new(pa_mainloop_api *a, const char *name) { return (pa_context *)2; }
void pa_context_set_state_callback(pa_context *c, pa_context_notify_cb_t cb, void *data) {
  state_callback = cb;
  state_data = data;
}
int pa_context_connect(pa_context *c, const char *server, pa_context_flags_t flags, const pa_spawn_api *spawn_api) {
  if (state_callback) state_callback(c, state_data);
  return 0;
}
pa_context_state_t pa_context_get_state(const pa_context *c) { return PA_CONTEXT_READY; }
void pa_context_disconnect(pa_context *c) {}
void pa_context_unref(pa_context *c) {}
pa_operation_state_t pa_operation_get_state(const pa_operation *o) { return PA_OPERATION_DONE; }
void pa_operation_unref(pa_operation *o) {}
pa_operation *pa_context_get_server_info(pa_context *c, pa_server_info_cb_t cb, void *data) {
  pa_server_info info = {0};
  info.default_sink_name = "fixture_sink";
  info.default_source_name = "fixture_source";
  cb(c, &info, data);
  return (pa_operation *)3;
}
pa_operation *pa_context_get_sink_info_by_name(pa_context *c, const char *name, pa_sink_info_cb_t cb, void *data) {
  setup();
  pa_sink_info info = {0};
  info.index = 1;
  info.name = "fixture_sink";
  info.description = "Fixture Sink";
  info.state = PA_SINK_IDLE;
  info.volume = volumes;
  info.mute = muted;
  cb(c, &info, 0, data);
  cb(c, NULL, 1, data);
  return (pa_operation *)3;
}
pa_operation *pa_context_set_sink_volume_by_index(pa_context *c, uint32_t i, const pa_cvolume *v, pa_context_success_cb_t cb, void *data) {
  volumes = *v;
  if (cb) cb(c, 1, data);
  return (pa_operation *)3;
}
pa_operation *pa_context_set_sink_mute_by_index(pa_context *c, uint32_t i, int mute, pa_context_success_cb_t cb, void *data) {
  const char *refuse = getenv("REVIEW_REFUSE_MUTE");
  int ok = !refuse || !*refuse;
  if (ok) muted = mute;
  if (cb) cb(c, ok, data);
  return (pa_operation *)3;
}
