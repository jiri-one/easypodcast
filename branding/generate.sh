#!/bin/sh
set -eu

if ! command -v rsvg-convert >/dev/null 2>&1; then
    printf '%s\n' 'rsvg-convert is required to generate the EasyPodcast icons.' >&2
    exit 1
fi

cd "$(dirname "$0")"
res=../app/android/app/src/main/res
linux=../app/linux/icons/hicolor
id=one.jiri.easypodcast

png() {
    rsvg-convert --width "$2" --height "$2" --output "$3" "$1"
}

# Android may crop the foreground to a 66 dp circle on its 108 dp canvas.
sed -e '/id="background"/d' \
    -e 's/id="microphone"/id="microphone" transform="translate(15.12 15.12) scale(0.72)"/' \
    icon.svg > icon-foreground.svg

for density in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
    name=${density%%:*}
    size=${density##*:}
    mkdir -p "$res/mipmap-$name"
    png icon.svg "$size" "$res/mipmap-$name/ic_launcher.png"
    png icon-foreground.svg "$((size * 9 / 4))" "$res/mipmap-$name/ic_launcher_foreground.png"
done

mkdir -p "$res/mipmap-anydpi-v26"
cat > "$res/mipmap-anydpi-v26/ic_launcher.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@android:color/white"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
EOF

mkdir -p "$linux/256x256/apps" "$linux/scalable/apps"
png icon.svg 256 "$linux/256x256/apps/$id.png"
cp icon.svg "$linux/scalable/apps/$id.svg"
