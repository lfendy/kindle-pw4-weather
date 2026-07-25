#!/usr/bin/env python3
"""Download Weather.

Usage:
    download_weather.py [-r | --rotated] [-m | --metric] [-b <battery> | --battery <battery>] [-t <template> | --template <template>] <geohash>
    download_weather.py (-h | --help)
    download_weather.py --version

Options:
    -h --help       Show this screen.
    --version       Show version.
    -r, --rotated   Rotate the output image 180 degrees.
    -m, --metric    Output with metric units. [default: True]
    -t <template>, --template <template>   Template file. [default: -]
    -b <battery>, --battery <battery>   Battery percentage (1-99) to display in footer.

Exit Codes:
    0   Success.
    1   General error.
    64  Usage - problem with command arguments.
    69  Unavailable - problem downloading weather data.
"""

from __future__ import annotations

import json
import logging
import ssl
import sys
import urllib.request
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from string import Template
from typing import Dict, List, Optional
from urllib.error import URLError

HERE = Path(f"{__file__}").parent
sys.path.insert(0, str((HERE / Path("../lib/python3.7/site-packages")).resolve()))

from docopt import docopt

NOMESSAGE = object()

SSL_CONTEXT = ssl.create_default_context(
    cafile=str((HERE / Path("../etc/ssl/certs/cacert.pem")).resolve())
)

logging.basicConfig(stream=sys.stderr, format="%(levelname)s@%(asctime)s: %(message)s")
logging.captureWarnings(True)
logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)


class Sysexits:
    EX_OK = 0
    EX_GENERAL = 1
    EX_USAGE = 64
    EX_UNAVAILABLE = 69


ICON_MAPPING: Dict[str, str] = {
    "clear": "skc",
    "sunny": "skc",
    "mostly_sunny": "few",
    "partly_cloudy": "sct",
    "cloudy": "ovc",
    "rain": "ra",
    "shower": "shra",
    "light_rain": "shra",
    "heavy_shower": "hi_shwrs",
    "storm": "tsra",
    "cyclone": "tsra",
    "windy": "wind",
    "hazy": "fg",
    "fog": "fg",
    "dusty": "du",
    "frost": "cold",
    "snow": "sn",
}


def icon_id(descriptor: str) -> str:
    return ICON_MAPPING.get(descriptor, "skc")


def fetch_json(url: str) -> dict:
    req = urllib.request.Request(url)
    try:
        with closing(urllib.request.urlopen(req, context=SSL_CONTEXT)) as resp:
            code = resp.getcode()
            if code // 100 != 2:
                die(Sysexits.EX_UNAVAILABLE, "HTTP %u %s", code, resp.reason)
            return json.load(resp)
    except URLError as e:
        die(Sysexits.EX_UNAVAILABLE, "Failed to retrieve weather data: %s", str(e))


def die(code=Sysexits.EX_GENERAL, msg=NOMESSAGE, *args):
    if msg is not NOMESSAGE:
        logger.error(msg, *args)
    sys.exit(code)


def fmt_hour(iso_str: str) -> str:
    utc_dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
    local_dt = utc_dt.astimezone()
    return local_dt.strftime("%-H:00")

def day_name(iso_str: str) -> str:
    utc_dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
    local_dt = utc_dt.astimezone()
    return local_dt.strftime("%a")


def day_num(iso_str: str) -> str:
    utc_dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
    local_dt = utc_dt.astimezone()
    return local_dt.strftime("%-d")




def wrap_text(words: List[str], max_len: int = 60) -> List[str]:
    lines = []
    current = ""
    for w in words:
        if not current:
            current = w
        elif len(current) + 1 + len(w) <= max_len:
            current += " " + w
        else:
            lines.append(current)
            current = w
    if current:
        lines.append(current)
    return lines


def build_hourly_svg(hourly_data: List[dict], n: int) -> str:
    if n < 1:
        n = 1
    seg = 930.0 / n
    parts = []
    for i, item in enumerate(hourly_data[:n]):
        x = 71 + (i + 0.5) * seg
        iid = icon_id(item.get("icon_descriptor", ""))
        temp = str(item["temp"])
        t = fmt_hour(item["time"])
        icon_x = x - 50
        rain = item.get("rain")
        rain_chance = f'{rain["chance"]}%' if rain and rain.get("chance") is not None else ""
        parts.append(f"""    <g>
      <text x="{x}" y="471" font-size="32" font-weight="bold" font-family="sans-serif" text-anchor="middle">{t}</text>
      <g transform="translate({icon_x}, 518) scale(1.0)">
        <use href="#{iid}"/>
      </g>
      <text x="{x}" y="651" font-size="28" font-family="sans-serif" text-anchor="middle">{rain_chance}</text>
      <text x="{x}" y="689" font-size="32" font-weight="bold" font-family="sans-serif" text-anchor="middle">{temp}C</text>
    </g>""")
    return "\n".join(parts)


def build_daily_svg(daily_data: List[dict], n: int) -> str:
    if n < 1:
        n = 1
    seg = 930.0 / n
    parts = []
    for i, item in enumerate(daily_data[:n]):
        xd = 71 + (i + 0.5) * seg
        iid = icon_id(item.get("icon_descriptor", ""))
        high = str(item["temp_max"])
        low = str(item["temp_min"] or item.get("now", {}).get("temp_now", "?"))
        d = day_name(item["date"])
        dt = day_num(item["date"])
        icon_x = xd - 71
        parts.append(f"""    <g>
      <text x="{xd}" y="1014" font-size="32" font-weight="bold" font-family="sans-serif" text-anchor="middle">{d}</text>
      <text x="{xd}" y="1059" font-size="40" font-family="sans-serif" text-anchor="middle">{dt}</text>
      <g transform="translate({icon_x}, 1077) scale(1.4)">
        <use href="#{iid}"/>
      </g>
      <text x="{xd}" y="1249" font-size="32" font-weight="bold" font-family="sans-serif" text-anchor="middle">{high}C</text>
      <text x="{xd}" y="1285" font-size="32" font-family="sans-serif" text-anchor="middle">{low}C</text>
    </g>""")
    return "\n".join(parts)


def build_summary_text(summary_words: List[str], max_len: int = 60) -> str:
    lines = wrap_text(summary_words, max_len)
    spans = []
    for line in lines:
        spans.append(f'      <tspan x="536" dy="1.2em">{line}</tspan>')
    return "\n".join(spans)


def main(argv: List[str]) -> Optional[int]:
    arguments = docopt(__doc__, argv=argv[1:], version="Download Weather 1.0.0")

    geohash = arguments["<geohash>"]
    rotated = arguments["--rotated"]

    logger.info('BOM: "%s"', geohash)

    daily_url = f"https://api.weather.bom.gov.au/v1/locations/{geohash}/forecasts/daily"
    hourly_url = f"https://api.weather.bom.gov.au/v1/locations/{geohash}/forecasts/hourly"

    daily_data = fetch_json(daily_url)
    hourly_data = fetch_json(hourly_url)

    hourly = hourly_data["data"]
    daily = daily_data["data"]
    today = daily[0] if daily else {}
    now = hourly[0] if hourly else {}
    now_temp = str(now.get("temp", "?"))
    now_icon = icon_id(now.get("icon_descriptor", ""))
    now_high = str(today.get("temp_max", "?"))
    now_low = str(today.get("temp_min") or today.get("now", {}).get("temp_now", "?"))
    summary = today.get("short_text", "")
    summary_words = summary.split()

    battery = arguments["--battery"]
    info_battery = f" {battery}% | " if battery and battery.isdigit() and 0 < int(battery) < 100 else ""

    now_dt = datetime.now().astimezone()
    info_day = now_dt.strftime("%a")
    info_date = now_dt.strftime("%d")
    info_report_time = now_dt.strftime("%b-%d %H:%M:%S")

    hourly_group = build_hourly_svg(hourly[:8], min(len(hourly), 8))
    daily_group = build_daily_svg(daily[:5], min(len(daily), 5))
    summary_svg = build_summary_text(summary_words, 60)

    template_path = arguments["--template"]
    if template_path == "-":
        if sys.stdin.isatty():
            logger.warning("Reading template from a terminal")
        template_string = sys.stdin.read()
    else:
        with open(template_path) as f:
            template_string = f.read()

    tpl = Template(template_string)
    output = tpl.safe_substitute({
        "INFO_DAY": info_day,
        "INFO_DATE": info_date,
        "NOW_ICON": now_icon,
        "NOW_TEMP": now_temp,
        "NOW_HIGH": now_high,
        "NOW_LOW": now_low,
        "SUMMARY_TEXT": summary_svg,
        "HOURLY_GROUP": hourly_group,
        "DAILY_GROUP": daily_group,
        "INFO_REPORT_TIME": info_report_time,
        "INFO_BATTERY": info_battery,
    })
    print(output, flush=True)
    return None


if __name__ == "__main__":
    sys.exit(main(sys.argv))
