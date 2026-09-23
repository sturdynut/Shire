#!/bin/sh
# Package the transparent source artwork at every standard macOS icon size.
set -eu

source_image=$1
output_icon=$2
mkdir -p "$(dirname "$output_icon")"
icon_work=$(mktemp -d "${TMPDIR:-/tmp}/shire-icon.XXXXXX")
trap 'rm -rf "$icon_work"' EXIT HUP INT TERM
iconset="$icon_work/AppIcon.iconset"
mkdir -p "$iconset"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_image" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$source_image" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$output_icon"
