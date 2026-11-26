#include "desktop_font.h"

FlValue* parse_desktop_font(const gchar* name) {
  if (name == nullptr) return nullptr;
  g_autoptr(PangoFontDescription) font =
      pango_font_description_from_string(name);
  const gchar* family = pango_font_description_get_family(font);
  double points =
      pango_font_description_get_size(font) / static_cast<double>(PANGO_SCALE);
  if (family == nullptr || *family == '\0' || points <= 0) return nullptr;
  if (pango_font_description_get_size_is_absolute(font)) points *= 72.0 / 96.0;

  FlValue* value = fl_value_new_map();
  fl_value_set_string_take(value, "family", fl_value_new_string(family));
  fl_value_set_string_take(value, "pointSize", fl_value_new_float(points));
  return value;
}

static void desktop_method_call_cb(FlMethodChannel*, FlMethodCall* call,
                                   gpointer settings) {
  if (g_strcmp0(fl_method_call_get_name(call), "getDesktopFont") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  g_autofree gchar* name = nullptr;
  g_object_get(settings, "gtk-font-name", &name, nullptr);
  g_autoptr(FlValue) font = parse_desktop_font(name);
  fl_method_call_respond_success(call, font, nullptr);
}

void register_desktop_font_channel(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "easypodcast/desktop", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, desktop_method_call_cb,
      g_object_ref(gtk_widget_get_settings(GTK_WIDGET(view))), g_object_unref);
}
