#include "../runner/desktop_preflight.h"
#include <gio/gio.h>

namespace {
bool stall = false;
GDBusMethodInvocation* pending = nullptr;
void read_all(GDBusConnection*, const gchar*, const gchar*, const gchar*,
              const gchar*, GVariant*, GDBusMethodInvocation* invocation,
              gpointer) {
  if (stall) {
    pending = G_DBUS_METHOD_INVOCATION(g_object_ref(invocation));
  } else {
    GVariantBuilder builder;
    g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sa{sv}}"));
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(a{sa{sv}})", &builder));
  }
}
}  // namespace

int main(int argc, char** argv) {
  g_test_init(&argc, &argv, nullptr);
  g_autoptr(GTestDBus) bus = g_test_dbus_new(G_TEST_DBUS_NONE);
  g_test_dbus_up(bus);
  // An absent portal must keep normal desktop fallback available.
  g_assert_true(desktop_preflight(true));
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusConnection) connection =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  g_assert_no_error(error);
  g_autoptr(GVariant) ownership = g_dbus_connection_call_sync(
      connection, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "RequestName",
      g_variant_new("(su)", "org.freedesktop.portal.Desktop", 0u),
      nullptr, G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
  g_assert_no_error(error);
  g_autoptr(GDBusNodeInfo) info = g_dbus_node_info_new_for_xml(
      "<node><interface name='org.freedesktop.portal.Settings'>"
      "<method name='ReadAll'><arg type='as' direction='in'/>"
      "<arg type='a{sa{sv}}' direction='out'/></method>"
      "</interface></node>", &error);
  g_assert_no_error(error);
  const GDBusInterfaceVTable vtable = {read_all, nullptr, nullptr, {nullptr}};
  const guint registration = g_dbus_connection_register_object(
      connection, "/org/freedesktop/portal/desktop", info->interfaces[0],
      &vtable, nullptr, nullptr, &error);
  g_assert_no_error(error);
  // A healthy portal reaches the normal GTK startup path.
  g_assert_true(desktop_preflight(true));
  stall = true;
  const gint64 started = g_get_monotonic_time();
  g_assert_false(desktop_preflight(true));
  const gint64 elapsed = g_get_monotonic_time() - started;
  g_assert_cmpint(elapsed, >=, 1500000);
  g_assert_cmpint(elapsed, <, 3500000);
  g_assert_nonnull(pending);
  g_dbus_method_invocation_return_dbus_error(
      pending, "org.freedesktop.DBus.Error.Failed", "Test finished");
  g_clear_object(&pending);
  g_dbus_connection_unregister_object(connection, registration);
  g_dbus_connection_close_sync(connection, nullptr, nullptr);
  g_clear_object(&connection);
  g_test_dbus_down(bus);
  g_print("Absent, responding, and stalled portal checks passed.\n");
  return 0;
}
