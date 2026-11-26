#include "desktop_font.h"

static void expect_font(const char* name, const char* family, double points) {
  g_autoptr(FlValue) font = parse_desktop_font(name);
  g_assert_nonnull(font);
  g_assert_cmpstr(fl_value_get_string(fl_value_lookup_string(font, "family")),
                  ==, family);
  g_assert_cmpfloat(
      fl_value_get_float(fl_value_lookup_string(font, "pointSize")), ==,
      points);
}

int main() {
  expect_font("Liberation Sans 18", "Liberation Sans", 18);
  expect_font("Liberation Sans Bold Italic 18", "Liberation Sans", 18);
  expect_font("Liberation Sans 24px", "Liberation Sans", 18);
  expect_font("Noto Sans 10.5", "Noto Sans", 10.5);
  g_assert_null(parse_desktop_font(nullptr));
  g_assert_null(parse_desktop_font("Sans"));
  g_assert_null(parse_desktop_font("18"));
}
