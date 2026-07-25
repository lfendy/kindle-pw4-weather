#!/bin/sh
cd /mnt/us/weather || exit 1
#LOG="/mnt/us/weather/var/log/display.log"
LOG="/tmp/display.log"
export FONTCONFIG_FILE="/mnt/us/fonts/fonts.conf"

# Load config
. etc/weather_config.sh

log() { echo "$(date): $1" >> "$LOG"; }

get_battery() {
  POWERD_OUTPUT=$(/usr/bin/powerd_test -s)
  batteryLevel=$(echo "$POWERD_OUTPUT" | awk -F: '/Battery Level/ {print substr($2, 1, length($2)-1) + 0}')
}

get_battery
log "battery level: $batteryLevel"

log "Starting weather download"
bin/download_weather.py ${METRIC:+"--metric"} --template usr/share/weather/weather_template.svg --battery $batteryLevel ${BOM_GEOHASH:+"$BOM_GEOHASH"} > var/cache/weather/weather_out.svg 2>/tmp/dl_weather.log

SVG_SIZE=$(wc -c < var/cache/weather/weather_out.svg)
log "SVG size: ${SVG_SIZE} bytes"

log "Converting SVG to PNG"
bin/rsvg-convert-armv7 --background-color=white -o var/cache/weather/weather_out.png var/cache/weather/weather_out.svg 2>>"$LOG"

if [ -s var/cache/weather/weather_out.png ]; then
    mkdir -p /mnt/us/screensaver
    cp var/cache/weather/weather_out.png /mnt/us/screensaver/weather.png
    log "Copied to screensaver folder OK"
else
    log "PNG empty, not copying"
fi
