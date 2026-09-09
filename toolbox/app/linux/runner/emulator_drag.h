#pragma once

#include <gtk/gtk.h>

// Own the original press for GDK's compositor handoff, and remember the exact
// widget whose press handler updated Flutter's pointer manager.
class EmulatorDragPress {
 public:
  EmulatorDragPress(GtkWidget* target, const GdkEvent* event)
      : event_(gdk_event_copy(event)) {
    g_weak_ref_init(&target_, G_OBJECT(target));
  }
  ~EmulatorDragPress() {
    g_weak_ref_clear(&target_);
    gdk_event_free(event_);
  }
  EmulatorDragPress(const EmulatorDragPress&) = delete;
  EmulatorDragPress& operator=(const EmulatorDragPress&) = delete;

  const GdkEvent* event() const { return event_; }

  // The compositor may consume the physical release during a move. Balance the
  // press in Flutter before handing control over, or it rejects the next down
  // as a duplicate. A later physical release is harmless: Flutter drops an up
  // for a button that is already up. This never changes GDK's real device state.
  bool release_to_flutter() {
    g_autoptr(GtkWidget) target = GTK_WIDGET(g_weak_ref_get(&target_));
    if (!target) return false;
    GdkEvent* release = gdk_event_copy(event_);
    release->type = GDK_BUTTON_RELEASE;
    release->button.send_event = TRUE;
    gboolean handled = FALSE;
    g_signal_emit_by_name(target, "button-release-event", release, &handled);
    gdk_event_free(release);
    return true;
  }

 private:
  GdkEvent* event_;
  GWeakRef target_;
};
