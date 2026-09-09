#ifndef TEMPO_DESKTOP_PREFLIGHT_H_
#define TEMPO_DESKTOP_PREFLIGHT_H_
// Check an already running portal before GTK's unbounded synchronous calls.
// Missing/unsupported portals use GTK's fallback; no service is started.
bool desktop_preflight(bool diagnostic);
#endif
