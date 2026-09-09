#include "desktop_preflight.h"
#include <gio/gio.h>

namespace {
struct Check {
  GMainLoop* loop;
  GCancellable* cancel;
  bool timed_out = false;
  bool responded = false;
};
void completed(GObject* source, GAsyncResult* result, gpointer data) {
  auto* check = static_cast<Check*>(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(source), result, &error);
  check->responded = reply != nullptr;
  check->timed_out |= error != nullptr &&
      (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT) ||
       g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_NO_REPLY) ||
       g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_TIMEOUT));
  g_main_loop_quit(check->loop);
}
void connected(GObject*, GAsyncResult* result, gpointer data) {
  auto* check = static_cast<Check*>(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusConnection) connection = g_bus_get_finish(result, &error);
  if (connection == nullptr) {
    g_main_loop_quit(check->loop);
    return;
  }
  const gchar* namespaces[] = {nullptr};
  g_dbus_connection_call(
      connection, "org.freedesktop.portal.Desktop",
      "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings",
      "ReadAll", g_variant_new("(^as)", namespaces), nullptr,
      G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, check->cancel, completed, check);
}
}  // namespace

bool desktop_preflight(bool diagnostic) {
  g_autoptr(GMainLoop) loop = g_main_loop_new(nullptr, FALSE);
  g_autoptr(GCancellable) cancel = g_cancellable_new();
  Check check{loop, cancel};
  const guint deadline = g_timeout_add(
      2500,
      [](gpointer data) -> gboolean {
        auto* check = static_cast<Check*>(data);
        check->timed_out = true;
        g_cancellable_cancel(check->cancel);
        return G_SOURCE_CONTINUE;
      }, &check);
  g_bus_get(G_BUS_TYPE_SESSION, cancel, connected, &check);
  g_main_loop_run(loop);
  g_source_remove(deadline);
  if (check.timed_out) {
    g_printerr(
        "Tempo Toolbox: the Linux desktop settings portal did not respond "
        "within 2.5 seconds. GTK startup can hang on this host.\n"
        "Check org.freedesktop.portal.Desktop Settings.ReadAll and your "
        "xdg-desktop-portal user service/backend configuration.\n"
        "Run tempo_toolbox --check-desktop to retry. See "
        "docs/toolbox/linux-desktop-startup.md for diagnostic commands. "
        "No session services or D-Bus settings were changed.\n");
    return false;
  }
  if (diagnostic) {
    g_print("Desktop settings portal: %s.\n", check.responded
        ? "responding" : "unavailable or unsupported; GTK fallback applies");
  }
  return true;
}
