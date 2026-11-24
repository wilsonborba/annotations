#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <libsecret/secret.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <string>

#include "flutter/generated_plugin_registrant.h"

static const SecretSchema kAnnotationsSessionSchema = {
    "com.asodya.annotations.session",
    SECRET_SCHEMA_NONE,
    {
        {"account", SECRET_SCHEMA_ATTRIBUTE_STRING},
        {nullptr, SECRET_SCHEMA_ATTRIBUTE_INTEGER},
    },
};

static void secure_storage_method_call_cb(FlMethodChannel* channel,
                                          FlMethodCall* method_call,
                                          gpointer user_data) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (g_strcmp0(method, "write") == 0) {
    if (fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "INVALID_ARGS", "Expected map arguments", nullptr));
    } else {
      FlValue* sid_val = fl_value_lookup_string(args, "session_id");
      FlValue* csrf_val = fl_value_lookup_string(args, "csrf_token");
      FlValue* owner_val = fl_value_lookup_string(args, "verified_user_id");
      if (sid_val == nullptr || csrf_val == nullptr ||
          fl_value_get_type(sid_val) != FL_VALUE_TYPE_STRING ||
          fl_value_get_type(csrf_val) != FL_VALUE_TYPE_STRING) {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "INVALID_ARGS", "Missing session_id or csrf_token", nullptr));
      } else {
        std::string payload = std::string(fl_value_get_string(sid_val)) + "\n" +
                              std::string(fl_value_get_string(csrf_val));
        if (owner_val != nullptr && fl_value_get_type(owner_val) == FL_VALUE_TYPE_STRING &&
            std::string(fl_value_get_string(owner_val)).size() > 0) {
          payload += "\n" + std::string(fl_value_get_string(owner_val));
        }
        g_autoptr(GError) error = nullptr;
        gboolean ok = secret_password_store_sync(
            &kAnnotationsSessionSchema, SECRET_COLLECTION_DEFAULT,
            "Annotations Session", payload.c_str(), nullptr, &error, "account",
            "default", nullptr);
        if (!ok) {
          response = FL_METHOD_RESPONSE(fl_method_error_response_new(
              "KEYRING_ERROR",
              error != nullptr ? error->message : "libsecret store failed",
              nullptr));
        } else {
          response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
        }
      }
    }
  } else if (g_strcmp0(method, "read") == 0) {
    g_autoptr(GError) error = nullptr;
    gchar* secret = secret_password_lookup_sync(
        &kAnnotationsSessionSchema, nullptr, &error, "account", "default",
        nullptr);
    if (error != nullptr) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "KEYRING_ERROR", error->message, nullptr));
    } else if (secret == nullptr) {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      std::string raw(secret);
      secret_password_free(secret);
      auto sep = raw.find('\n');
      if (sep == std::string::npos) {
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      } else {
        g_autoptr(FlValue) map = fl_value_new_map();
        fl_value_set_string_take(
            map, "session_id", fl_value_new_string(raw.substr(0, sep).c_str()));
        auto second_sep = raw.find('\n', sep + 1);
        if (second_sep != std::string::npos) {
          fl_value_set_string_take(
              map, "csrf_token", fl_value_new_string(raw.substr(sep + 1, second_sep - sep - 1).c_str()));
          if (second_sep + 1 < raw.size()) {
            fl_value_set_string_take(
                map, "verified_user_id", fl_value_new_string(raw.substr(second_sep + 1).c_str()));
          }
        } else {
          fl_value_set_string_take(
              map, "csrf_token", fl_value_new_string(raw.substr(sep + 1).c_str()));
        }
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(map));
      }
    }
  } else if (g_strcmp0(method, "delete") == 0) {
    g_autoptr(GError) error = nullptr;
    secret_password_clear_sync(&kAnnotationsSessionSchema, nullptr, &error,
                               "account", "default", nullptr);
    if (error != nullptr) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "KEYRING_ERROR", error->message, nullptr));
    } else {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Annotations");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Annotations");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
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

  g_autoptr(FlPluginRegistrar) secure_registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "SecureStorage");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) secure_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(secure_registrar),
      "com.asodya.annotations/secure_storage", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      secure_channel, secure_storage_method_call_cb, nullptr, nullptr);

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
  g_set_application_name("Annotations");

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
