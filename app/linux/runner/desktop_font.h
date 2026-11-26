#pragma once

#include <flutter_linux/flutter_linux.h>

FlValue* parse_desktop_font(const gchar* name);
void register_desktop_font_channel(FlView* view);
