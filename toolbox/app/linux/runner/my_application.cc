#include "my_application.h"
#include "desktop_identity.h"
#include "emulator_drag.h"
#include <memory>

#include <flutter_linux/flutter_linux.h>
#include <epoxy/egl.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// GTK uses GLX on X11 while Flutter uses EGL. Release each API's current
// context at view and frame boundaries; otherwise GLX can fail with BadAccess
// when an EGL context from a newly opened or closed view remains bound.
static void (*original_view_realize)(GtkWidget*) = nullptr;
static void (*original_view_unrealize)(GtkWidget*) = nullptr;
static void clear_graphics_context() {
  gdk_gl_context_clear_current();
  eglReleaseThread();
}
static gboolean prepare_frame_context(GSignalInvocationHint*, guint,
                                      const GValue*, gpointer) {
  clear_graphics_context();
  return TRUE;
}
static void realize_view(GtkWidget* widget) {
  clear_graphics_context();
  original_view_realize(widget);
  clear_graphics_context();
}
static void unrealize_view(GtkWidget* widget) {
  clear_graphics_context();
  original_view_unrealize(widget);
  clear_graphics_context();
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Choose an alpha visual before native realization, including engine-created
// secondary windows. The Toolbox stays opaque because its Flutter scene is opaque.
static gboolean prepare_view_visual(GSignalInvocationHint*, guint count,
                                   const GValue* values, gpointer) {
  if (count == 0) return TRUE;
  GtkWidget* widget = GTK_WIDGET(g_value_get_object(values));
  if (!FL_IS_VIEW(widget) && !GTK_IS_WINDOW(widget)) return TRUE;
  GtkWidget* top = gtk_widget_get_toplevel(widget);
  if (GTK_IS_WINDOW(top) && !gtk_widget_get_realized(top)) {
    GdkVisual* visual = gdk_screen_get_rgba_visual(gtk_widget_get_screen(top));
    if (visual) gtk_widget_set_visual(top, visual);
  }
  return TRUE;
}

static void announce_emulator_decorations(GtkWidget* widget) {
#ifdef GDK_WINDOWING_WAYLAND
  GdkWindow* native = gtk_widget_get_window(widget);
  // GTK3's Wayland set_decorations implementation is a no-op. Explicitly own
  // decorations so KWin does not add a server-side frame around our clear view.
  if (native && GDK_IS_WAYLAND_WINDOW(native))
    gdk_wayland_window_announce_csd(native);
#endif
}

// The pinned Flutter window API realizes a plain GtkWindow before constructing
// its FlView. At that point no view callback exists yet. Wrap GtkWindow's realize
// virtual function so the named emulator gets an alpha visual before its native
// surface is allocated. All other windows retain their normal realization.
static void (*original_window_realize)(GtkWidget*) = nullptr;
static void realize_emulator_window(GtkWidget* widget) {
  const gchar* title = gtk_window_get_title(GTK_WINDOW(widget));
  if (g_strcmp0(title, "Tempo Emulator") == 0) {
    GdkVisual* visual = gdk_screen_get_rgba_visual(gtk_widget_get_screen(widget));
    if (visual) gtk_widget_set_visual(widget, visual);
    gtk_window_set_decorated(GTK_WINDOW(widget), FALSE);
  }
  original_window_realize(widget);
  if (g_strcmp0(title, "Tempo Emulator") == 0)
    announce_emulator_decorations(widget);
}

// Match by engine view ID: window_manager only knows the primary window.
static FlView* find_view(GtkWidget* widget, int64_t id) {
  if (FL_IS_VIEW(widget) && fl_view_get_id(FL_VIEW(widget)) == id)
    return FL_VIEW(widget);
  if (!GTK_IS_CONTAINER(widget)) return nullptr;
  GList* children = gtk_container_get_children(GTK_CONTAINER(widget));
  FlView* result = nullptr;
  for (GList* child = children; child && !result; child = child->next)
    result = find_view(GTK_WIDGET(child->data), id);
  g_list_free(children);
  return result;
}

// Dart receives pointer input asynchronously, after GTK's current event has
// gone away. Keep the original press (device, timestamp and root coordinates)
// on its view. An emission hook sees it before Flutter consumes the event box's
// button-press signal; a later signal handler would never see handled presses.
static gboolean capture_emulator_press(GSignalInvocationHint*, guint count,
                                      const GValue* values, gpointer) {
  if (count < 2) return TRUE;
  GtkWidget* target = GTK_WIDGET(g_value_get_object(values));
  GtkWidget* widget = target;
  while (widget && !FL_IS_VIEW(widget)) widget = gtk_widget_get_parent(widget);
  if (!widget || !g_object_get_data(G_OBJECT(widget), "tempo-emulator-configured"))
    return TRUE;
  GdkEvent* event = static_cast<GdkEvent*>(g_value_get_boxed(values + 1));
  if (event && event->type == GDK_BUTTON_PRESS)
    g_object_set_data_full(G_OBJECT(widget), "tempo-emulator-press",
                          new EmulatorDragPress(target, event),
                          [](gpointer data) { delete static_cast<EmulatorDragPress*>(data); });
  return TRUE;
}

static void emulator_window_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  FlValue* args = fl_method_call_get_args(call);
  FlValue* id = fl_value_lookup_string(args, "viewId");
  FlView* view = nullptr;
  GList* windows = gtk_window_list_toplevels();
  if (id && fl_value_get_type(id) == FL_VALUE_TYPE_INT) {
    for (GList* item = windows; item && !view; item = item->next)
      view = find_view(GTK_WIDGET(item->data), fl_value_get_int(id));
  }
  g_list_free(windows);
  if (!view) {
    fl_method_call_respond_error(call, "view_not_found", "Emulator view is not attached", nullptr, nullptr);
    return;
  }
  GtkWidget* widget = gtk_widget_get_toplevel(GTK_WIDGET(view));
  GtkWindow* window = GTK_WINDOW(widget);
  const gchar* method = fl_method_call_get_name(call);
  if (g_str_equal(method, "configure")) {
    g_object_set_data(G_OBJECT(view), "tempo-emulator-configured", GINT_TO_POINTER(1));
    gtk_window_set_title(window, "Tempo Emulator");
    gtk_window_set_decorated(window, FALSE);
    announce_emulator_decorations(widget);
    gtk_widget_set_app_paintable(widget, TRUE);
    GdkRGBA clear = {0, 0, 0, 0};
    fl_view_set_background_color(view, &clear);
    // Flutter's GTK GL view already requests an alpha-capable visual.
    GtkCssProvider* css = gtk_css_provider_new();
    gtk_css_provider_load_from_data(css, "window { background-color: transparent; background-image: none; }", -1, nullptr);
    gtk_style_context_add_provider(gtk_widget_get_style_context(widget), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);
    if (GdkWindow* native = gtk_widget_get_window(widget))
      gdk_window_set_opaque_region(native, nullptr);
    gtk_widget_queue_draw(widget);
  } else if (g_str_equal(method, "setSize")) {
    FlValue* width = fl_value_lookup_string(args, "width");
    FlValue* height = fl_value_lookup_string(args, "height");
    if (width && height && fl_value_get_type(width) == FL_VALUE_TYPE_FLOAT &&
        fl_value_get_type(height) == FL_VALUE_TYPE_FLOAT) {
      gtk_window_resize(window, static_cast<gint>(fl_value_get_float(width)),
                        static_cast<gint>(fl_value_get_float(height)));
    }
  } else if (g_str_equal(method, "close")) {
    gtk_window_close(window);
  } else if (g_str_equal(method, "startDrag")) {
    std::unique_ptr<EmulatorDragPress> press(static_cast<EmulatorDragPress*>(
        g_object_steal_data(G_OBJECT(view), "tempo-emulator-press")));
    if (!press || !press->release_to_flutter()) {
      fl_method_call_respond_error(call, "missing_pointer_press",
                                  "Dragging requires a pointer press", nullptr, nullptr);
      return;
    }
    const GdkEventButton& button = press->event()->button;
    gdk_window_begin_move_drag_for_device(gtk_widget_get_window(widget), gdk_event_get_device(press->event()),
        button.button, static_cast<gint>(button.x_root),
        static_cast<gint>(button.y_root), button.time);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Match the default native frame used by Flutter secondary windows.
  gtk_window_set_title(window, "Tempo Toolbox");

  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable) {
    g_autofree gchar* bundle = g_path_get_dirname(executable);
    g_autofree gchar* icon = g_build_filename(
        bundle, "data", "flutter_assets", "packages", "tempo_assets", "tempo",
        "web", "icon-512.png", nullptr);
    register_desktop_identity(APPLICATION_ID, executable, icon);
    gtk_window_set_default_icon_from_file(icon, nullptr);
    gtk_window_set_icon_from_file(window, icon, nullptr);
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  // The pinned Linux Impeller GLES renderer aliases paths and rounded clips
  // on this embedder's framebuffer. Skia preserves coverage antialiasing,
  // including in additional transparent views. Engine switches can override
  // this default when validating a newer renderer.
  fl_dart_project_set_enable_impeller(project, FALSE);
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  // Prefer local file URIs over one-shot portal keys when the source offers
  // both. Keep portal-only sources supported; STRING is not a file target.
  GtkTargetEntry drop_targets[] = {
      {const_cast<gchar*>("text/uri-list"), GTK_TARGET_OTHER_APP, 0},
      {const_cast<gchar*>("application/vnd.portal.filetransfer"),
       GTK_TARGET_OTHER_APP, 0},
  };
  GtkTargetList* drop_target_list = gtk_target_list_new(drop_targets, 2);
  gtk_drag_dest_set_target_list(GTK_WIDGET(view), drop_target_list);
  gtk_target_list_unref(drop_target_list);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "tempo/emulator_window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, emulator_window_call, nullptr, nullptr);


  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  gpointer clock_class = g_type_class_ref(GDK_TYPE_FRAME_CLOCK);
  g_signal_add_emission_hook(g_signal_lookup("before-paint", GDK_TYPE_FRAME_CLOCK),
                            0, prepare_frame_context, nullptr, nullptr);
  g_signal_add_emission_hook(g_signal_lookup("after-paint", GDK_TYPE_FRAME_CLOCK),
                            0, prepare_frame_context, nullptr, nullptr);
  g_type_class_unref(clock_class);
  GtkWidgetClass* view_class = GTK_WIDGET_CLASS(g_type_class_ref(fl_view_get_type()));
  original_view_realize = view_class->realize;
  original_view_unrealize = view_class->unrealize;
  view_class->realize = realize_view;
  view_class->unrealize = unrealize_view;
  g_type_class_unref(view_class);
  GtkWidgetClass* window_class = GTK_WIDGET_CLASS(g_type_class_ref(GTK_TYPE_WINDOW));
  original_window_realize = window_class->realize;
  window_class->realize = realize_emulator_window;
  g_type_class_unref(window_class);

  g_signal_add_emission_hook(g_signal_lookup("button-press-event", GTK_TYPE_WIDGET),
                            0, capture_emulator_press, nullptr, nullptr);
  // Engine secondary windows can realize before their FlView is parented.
  g_signal_add_emission_hook(g_signal_lookup("screen-changed", GTK_TYPE_WIDGET),
                            0, prepare_view_visual, nullptr, nullptr);
  g_signal_add_emission_hook(g_signal_lookup("hierarchy-changed", GTK_TYPE_WIDGET),
                            0, prepare_view_visual, nullptr, nullptr);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
