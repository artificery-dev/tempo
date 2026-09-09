#include "desktop_identity.h"

#include <glib.h>

namespace {
constexpr char kGroup[] = "Desktop Entry";
constexpr char kManaged[] = "X-Tempo-PortableBundle";

// Exec has its own quoting rules; it is not a shell command. GKeyFile handles
// the second layer of escaping when serializing the desktop entry.
gchar* quote_executable(const char* executable) {
  GString* quoted = g_string_new("\"");
  for (const char* c = executable; *c; ++c) {
    if (*c == '%') {
      g_string_append(quoted, "%%");
      continue;
    }
    if (*c == '"' || *c == '\\' || *c == '$' || *c == '`')
      g_string_append_c(quoted, '\\');
    g_string_append_c(quoted, *c);
  }
  g_string_append_c(quoted, '"');
  return g_string_free(quoted, FALSE);
}
}  // namespace

void register_desktop_identity(const char* application_id,
                               const char* executable, const char* icon) {
  if (!g_file_test(icon, G_FILE_TEST_IS_REGULAR)) return;
  g_autofree gchar* name = g_strconcat(application_id, ".desktop", nullptr);
  for (const gchar* const* dir = g_get_system_data_dirs(); *dir; ++dir) {
    g_autofree gchar* installed =
        g_build_filename(*dir, "applications", name, nullptr);
    if (g_file_test(installed, G_FILE_TEST_EXISTS)) return;
  }
  g_autofree gchar* applications =
      g_build_filename(g_get_user_data_dir(), "applications", nullptr);
  g_autofree gchar* path = g_build_filename(applications, name, nullptr);
  g_autoptr(GKeyFile) entry = g_key_file_new();
  if (g_file_test(path, G_FILE_TEST_EXISTS)) {
    if (!g_key_file_load_from_file(entry, path, G_KEY_FILE_KEEP_COMMENTS, nullptr) ||
        !g_key_file_get_boolean(entry, kGroup, kManaged, nullptr) ||
        g_key_file_get_boolean(entry, kGroup, "Hidden", nullptr))
      return;
  }
  g_autofree gchar* command = quote_executable(executable);
  g_autofree gchar* previous_icon =
      g_key_file_get_string(entry, kGroup, "Icon", nullptr);
  g_autofree gchar* previous_command =
      g_key_file_get_string(entry, kGroup, "Exec", nullptr);
  if (g_strcmp0(previous_icon, icon) == 0 &&
      g_strcmp0(previous_command, command) == 0)
    return;

  g_key_file_set_string(entry, kGroup, "Type", "Application");
  g_key_file_set_string(entry, kGroup, "Name", "Tempo Toolbox");
  g_key_file_set_string(entry, kGroup, "Exec", command);
  g_key_file_set_string(entry, kGroup, "Icon", icon);
  g_key_file_set_string(entry, kGroup, "StartupWMClass", application_id);
  g_key_file_set_boolean(entry, kGroup, "Terminal", FALSE);
  // Supply the compositor's metadata without adding a development build to
  // the application menu every time a checkout is run.
  g_key_file_set_boolean(entry, kGroup, "NoDisplay", TRUE);
  g_key_file_set_boolean(entry, kGroup, kManaged, TRUE);
  if (g_mkdir_with_parents(applications, 0755) == 0)
    g_key_file_save_to_file(entry, path, nullptr);
}
