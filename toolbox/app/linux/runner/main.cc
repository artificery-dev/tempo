#include "my_application.h"
#include "desktop_preflight.h"

#include <cstring>

int main(int argc, char** argv) {
  const bool diagnostic = argc == 2 && std::strcmp(argv[1], "--check-desktop") == 0;
  if (!desktop_preflight(diagnostic)) return 69;
  if (diagnostic) return 0;
  // Prefer the desktop's file chooser (KDE, GNOME, etc.). GTK retains its
  // local fallback when a FileChooser portal is unavailable. Respect overrides.
  g_setenv("GTK_USE_PORTAL", "1", FALSE);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
