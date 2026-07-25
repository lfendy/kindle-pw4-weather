#!/bin/sh


cd /mnt/us/weather || exit 1

export PATH="/mnt/us/libkh/bin/:$PATH"
BIN_DIR=bin
CONFIG_DIR=etc
STATIC_DIR=usr/share/weather
CACHE_DIR=var/cache/weather

DOWNLOAD_WEATHER="$BIN_DIR/download_weather.py"
export FONTCONFIG_FILE="/mnt/us/fonts/fonts.conf"
RSVG_CONVERT="$BIN_DIR/rsvg-convert-armv7"
PNGCRUSH="$BIN_DIR/pngcrush"
EIPS="/usr/sbin/eips"

TEMPLATE="$STATIC_DIR/weather_template.svg"

# shellcheck source=../etc/weather_config.sh
. "$CONFIG_DIR/weather_config.sh"

# save current images as old; mostly useful for debugging
mv "$CACHE_DIR/weather_out.svg" "$CACHE_DIR/weather_out.svg.old"
mv "$CACHE_DIR/weather_out.png" "$CACHE_DIR/weather_out.png.old"
mv "$CACHE_DIR/weather.png" "$CACHE_DIR/weather.png.old"

get_battery() {
  POWERD_OUTPUT=$(/usr/bin/powerd_test -s)
  batteryLevel=$(echo "$POWERD_OUTPUT" | awk -F: '/Battery Level/ {print substr($2, 1, length($2)-1) + 0}')
}

get_battery

"$DOWNLOAD_WEATHER" ${ROTATED:+"--rotated"} ${METRIC:+"--metric"} --template ${TEMPLATE:?"missing TEMPLATE"} --battery $batteryLevel ${BOM_GEOHASH:+"$BOM_GEOHASH"} > "$CACHE_DIR/weather_out.svg" 2>/dev/null

# convert the svg to a png with white background (no transparency allowed!)
"$RSVG_CONVERT" --background-color=white -o "$CACHE_DIR/weather_out.png" "$CACHE_DIR/weather_out.svg"

# change png to greyscale without alpha (color type (-c) 0)
cp "$CACHE_DIR/weather_out.png" "$CACHE_DIR/weather.png"

# clear the screen twice to prevent ghosting
fbink -c --flash
# (cleared above)

# if everything worked, put the weather up; if not, show an error
if [ -e "$CACHE_DIR/weather.png" ]; then
    fbink -g file="$CACHE_DIR/weather.png",w=-2,h=-2 --flash
    exit $?
else
    fbink -g file="$STATIC_DIR/error.png",w=-2,h=-2 --flash
    _RET=$?
    if [ "$_RET" -ne 0 ]; then
        exit "$_RET"
    else
        exit 1
    fi
fi
