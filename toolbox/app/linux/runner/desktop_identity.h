#ifndef TEMPO_DESKTOP_IDENTITY_H_
#define TEMPO_DESKTOP_IDENTITY_H_

// Give portable/development bundles an identity that Wayland desktops can
// resolve. Installed or user-created launchers take precedence.
void register_desktop_identity(const char* application_id,
                               const char* executable, const char* icon);

#endif  // TEMPO_DESKTOP_IDENTITY_H_
