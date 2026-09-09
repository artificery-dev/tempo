#include "../runner/emulator_drag.h"

// Mirrors Flutter's documented pointer-manager transition: another down while
// held is discarded. Exercise the GTK signal handoff, including missing and
// delayed physical releases, without moving any user windows.
struct PointerState { bool down = false; int presses = 0; int releases = 0; };
static gboolean pressed(GtkWidget*, GdkEventButton*, gpointer data) {
  auto* state = static_cast<PointerState*>(data);
  if (state->down) return FALSE;
  state->down = true;
  state->presses++;
  return TRUE;
}
static gboolean released(GtkWidget*, GdkEventButton*, gpointer data) {
  auto* state = static_cast<PointerState*>(data);
  if (!state->down) return FALSE;
  state->down = false;
  state->releases++;
  return TRUE;
}
int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  GtkWidget* target = gtk_event_box_new();
  g_object_ref_sink(target);
  PointerState state;
  g_signal_connect(target, "button-press-event", G_CALLBACK(pressed), &state);
  g_signal_connect(target, "button-release-event", G_CALLBACK(released), &state);
  GdkEvent* event = gdk_event_new(GDK_BUTTON_PRESS);
  event->button.button = 1;
  event->button.time = 1234;
  event->button.x_root = 50;
  event->button.y_root = 60;
  for (int i = 0; i < 12; i++) {
    gboolean handled = FALSE;
    g_signal_emit_by_name(target, "button-press-event", event, &handled);
    g_assert_true(handled);
    EmulatorDragPress drag(target, event);
    g_assert_true(drag.release_to_flutter());
    g_assert_false(state.down);
    g_assert_cmpint(drag.event()->type, ==, GDK_BUTTON_PRESS);
    g_assert_cmpuint(drag.event()->button.time, ==, 1234);
    g_assert_cmpfloat(drag.event()->button.x_root, ==, 50);
    if (i % 2 == 0) {
      GdkEvent* physical = gdk_event_copy(event);
      physical->type = GDK_BUTTON_RELEASE;
      g_signal_emit_by_name(target, "button-release-event", physical, &handled);
      gdk_event_free(physical);
    }
  }
  g_assert_cmpint(state.presses, ==, 12);
  g_assert_cmpint(state.releases, ==, 12);
  EmulatorDragPress stale(target, event);
  g_object_unref(target);
  g_assert_false(stale.release_to_flutter());
  gdk_event_free(event);
  g_print("12 consecutive drag handoffs, duplicate release, original event, and destroyed target checks passed.\n");
}
