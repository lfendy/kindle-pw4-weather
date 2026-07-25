#!/bin/sh
#
# Weather display loop with robust wifi connect (adapted from
# wake_and_connect.sh) and rtcwake-based suspend between updates.
#
# EDIT THIS: your saved network's SSID, exactly as it appears in
# lipc-hash-prop profileData's "essid" field.
SSID="Aussie Broadband 2533"

#LOG="/mnt/us/weather/var/log/display.log"
LOG="/mnt/us/documents/display_log.txt"
MAX_LOG_SIZE=524288   # 512KB, trim log if it grows past this
INTERVAL=21600
UPDATE_SCRIPT="/mnt/us/weather/bin/update_screensaver.sh"
export PATH="/mnt/us/libkh/bin/:$PATH"

# How long to let the SoC/radio settle after rtcwake resume before we
# start hammering lipc. In the log, the first lipc-get-prop call after
# resume took ~100s to even return - this gives that time to happen
# quietly instead of racing it.
WAKE_SETTLE=10

# How long to wait for com.lab126.wifid to become reachable on the lipc
# bus before we conclude it's actually dead and needs a restart.
WIFID_WAIT_TIMEOUT=30

log() { echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG"; }

GOV_PATH=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
FREQ_PATH=/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq

set_cpu_performance() {
    if [ -w "$GOV_PATH" ]; then
        echo performance > "$GOV_PATH" 2>/dev/null
    fi
    log "CPU governor=$(cat "$GOV_PATH" 2>/dev/null) freq=$(cat "$FREQ_PATH" 2>/dev/null)"
}

set_cpu_powersave() {
    if [ -w "$GOV_PATH" ]; then
        echo powersave > "$GOV_PATH" 2>/dev/null
    fi
}

# Run lipc-get-prop with a timeout so a single stalled call can't block
# the script indefinitely. The 2026-07-22/23 logs show individual
# lipc-get-prop calls blocking for 30-90+ seconds during bad episodes;
# without a bound, a handful of these back to back is what turned a
# 15-second status dump into multi-minute stalls throughout the script.
lipc_get() {
    if command -v timeout > /dev/null 2>&1; then
        timeout 15 lipc-get-prop "$@" 2>&1
    else
        lipc-get-prop "$@" 2>&1
    fi
}

trim_log() {
    if [ -f "$LOG" ]; then
        SIZE=$(wc -c < "$LOG" 2>/dev/null)
        if [ -n "$SIZE" ] && [ "$SIZE" -gt "$MAX_LOG_SIZE" ]; then
            tail -c 262144 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
        fi
    fi
}

dump_wifi_state() {
    TAG="$1"
    log "[$TAG] profileCount=$(lipc_get com.lab126.wifid profileCount)"
    if command -v timeout > /dev/null 2>&1; then
        log "[$TAG] profileData0=$(echo "{index=(0)}" | timeout 15 lipc-hash-prop com.lab126.wifid profileData 2>&1)"
    else
        log "[$TAG] profileData0=$(echo "{index=(0)}" | lipc-hash-prop com.lab126.wifid profileData 2>&1)"
    fi
    log "[$TAG] cmState=$(lipc_get com.lab126.wifid cmState)"
    log "[$TAG] wifidEnable=$(lipc_get com.lab126.wifid enable)"
    log "[$TAG] powerdState=$(lipc_get com.lab126.powerd state)"
}

# Log upstart status of the whole wifi service trio. wifid is the one
# that answers com.lab126.wifid over lipc, but it apparently depends on
# wifim and wifis - if either of those is stopped/crashed, wifid can be
# "running" and still answering lipc calls with garbage/stale state.
# This is purely diagnostic for now; once we see a log with a failure,
# we'll know which of the three is actually the culprit.
dump_service_status() {
    TAG="$1"
    log "[$TAG] wifid=$(initctl status wifid 2>&1)"
    log "[$TAG] wifim=$(initctl status wifim 2>&1)"
    log "[$TAG] wifis=$(initctl status wifis 2>&1)"
}

# Poll cmState until it returns a clean answer, i.e. until wifid is
# actually registered on the lipc bus AND answering without error. This
# is distinct from "connected" - it just means the daemon itself is
# alive and responsive. Originally this only checked for
# lipcErrNoSuchSource, but the 2026-07-22 log showed it wave through a
# lipcErrTimedOut response as "reachable" - any lipcErr*/failure text
# means wifid isn't actually healthy yet, so reject all of them.
# Returns 0 if wifid became reachable within TIMEOUT seconds, 1 otherwise.
wait_for_wifid() {
    TIMEOUT="$1"
    n=0
    while [ "$n" -lt "$TIMEOUT" ]; do
        RESULT=$(lipc_get com.lab126.wifid cmState)
        if ! echo "$RESULT" | grep -Eqi "lipcErr|failed to access"; then
            log "wifid reachable after ${n}s (cmState=$RESULT)"
            return 0
        fi
        sleep 1
        n=$((n + 1))
    done
    log "wifid still unreachable after ${TIMEOUT}s (last result: $RESULT)"
    return 1
}

# Poll `initctl status $SVC` until its output contains $WANT (e.g.
# "start/running" or "stop/"). Used so restart_wifid can verify each
# stop/start actually took effect instead of trusting a fixed sleep -
# the 2026-07-22 log showed a stop/start sequence block for 49 minutes
# with no visibility into which command was actually stuck.
# `initctl status` itself is wrapped in `timeout` here too - the
# 2026-07-23 log showed a run where individual `initctl status` calls
# (not just stop/start) were each taking ~60s+ during a bad episode,
# which blew through this function's budget silently since only
# stop/start were bounded before.
wait_for_service_state() {
    SVC="$1"; WANT="$2"; TIMEOUT="$3"
    n=0
    while [ "$n" -lt "$TIMEOUT" ]; do
        if command -v timeout > /dev/null 2>&1; then
            ST=$(timeout 10 initctl status "$SVC" 2>&1)
        else
            ST=$(initctl status "$SVC" 2>&1)
        fi
        if echo "$ST" | grep -q "$WANT"; then
            log "  $SVC reached '$WANT' after ${n}s ($ST)"
            return 0
        fi
        sleep 1
        n=$((n + 1))
    done
    log "  $SVC did NOT reach '$WANT' within ${TIMEOUT}s (last: $ST)"
    return 1
}

# Wrap a command with `timeout` if it's available on this system, so a
# hung upstart stop/start can't silently block the whole script. The
# 2026-07-22 log shows a stop/start sequence that took 49 minutes to
# return with zero intermediate logging - this at least bounds it and
# tells us which specific command got stuck.
run_bounded() {
    if command -v timeout > /dev/null 2>&1; then
        timeout 20 "$@" > /dev/null 2>&1
    else
        "$@" > /dev/null 2>&1
    fi
}

# Last resort: actually restart the wifi service trio rather than
# toggling wifid's "enable" prop. In the log, toggling enable 0->1 while
# wifid was still coming up after resume is what coincided with
# profileCount dropping to 0 (saved profile effectively lost for the
# rest of that cycle). Restarting cleanly is a better reset.
#
# `initctl list` on this device shows three related services: wifid,
# wifim, wifis. wifid is the one that answers com.lab126.wifid over
# lipc, but it likely depends on wifim/wifis underneath - restarting
# only wifid may leave a wedged dependency in place. Stop in reverse
# dependency order and start back up the same way wifid, wifim, wifis
# depend on each other; if the assumed order below (wifis -> wifim ->
# wifid, i.e. supplicant-ish layer up to the lipc-facing daemon) turns
# out to be wrong once you see the dump_service_status output, swap it.
#
# Each stop/start is verified with wait_for_service_state instead of a
# fixed sleep - the previous version's blind sleeps hid the fact that
# the sequence can hang for tens of minutes, and that the trio can end
# up with wifid/wifis stuck in stop/waiting rather than running.
restart_wifid() {
    log "Restarting wifi service trio (wifid, wifim, wifis)"

    log "  stopping wifid"
    run_bounded stop wifid
    wait_for_service_state wifid "stop/" 15

    log "  stopping wifim"
    run_bounded stop wifim
    wait_for_service_state wifim "stop/" 15

    log "  stopping wifis"
    run_bounded stop wifis
    wait_for_service_state wifis "stop/" 15

    sleep 1

    log "  starting wifis"
    run_bounded start wifis
    wait_for_service_state wifis "start/running" 15

    log "  starting wifim"
    run_bounded start wifim
    wait_for_service_state wifim "start/running" 15

    log "  starting wifid"
    run_bounded start wifid
    wait_for_service_state wifid "start/running" 15
}

# Re-assert deferSuspend + abortSuspend periodically in the background
# while a wifi connect attempt is in flight, so powerd can't suspend us
# mid-connect. Must be explicitly stopped before we deliberately suspend
# via rtcwake, or it will fight that suspend too.
keep_awake() {
    while true; do
        lipc-set-prop com.lab126.powerd deferSuspend 1 2>/dev/null
        lipc-set-prop com.lab126.powerd abortSuspend 1 2>/dev/null
        sleep 5
    done
}

start_keep_awake() {
    keep_awake &
    KEEP_AWAKE_PID=$!
}

stop_keep_awake() {
    if [ -n "$KEEP_AWAKE_PID" ]; then
        kill "$KEEP_AWAKE_PID" 2>/dev/null
        KEEP_AWAKE_PID=""
    fi
    lipc-set-prop com.lab126.powerd deferSuspend 0 2>/dev/null
}
trap 'stop_keep_awake' EXIT

trim_log
log "=== Weather Display Mode ==="

# Stop GUI layer (NOT framework, NOT powerd, NOT lab126)
stop lab126_gui       > /dev/null 2>&1
stop otaupd           > /dev/null 2>&1
stop phd              > /dev/null 2>&1
stop tmd              > /dev/null 2>&1
stop x                > /dev/null 2>&1
stop todo             > /dev/null 2>&1
stop mcsd              > /dev/null 2>&1
sleep 2

log "Services stopped"

# Prevent screensaver
lipc-set-prop com.lab126.powerd preventScreenSaver 1
# NOTE: CPU governor is no longer pinned to powersave here. See
# set_cpu_performance/set_cpu_powersave below - the 2026-07-23 log
# showed lipc AND initctl calls both stalling uniformly across
# unrelated daemons (initctl itself returned "Did not receive a
# reply"), which looks like a CPU-starvation symptom rather than a
# wifid-specific bug. Running pinned to the lowest fixed frequency for
# the entire awake window is a likely contributor - every dbus/lipc
# round-trip costs real CPU cycles to marshal. Performance is used
# during the actual wifi/update work, powersave only during suspend.

# Disable WiFi probe file
touch /mnt/us/WIFI_NO_NET_PROBE

dump_wifi_state "startup"
log "Entering main loop"

FIRST_ITERATION=1

while true; do
    trim_log

    if [ "$FIRST_ITERATION" -eq 0 ]; then
        # Only relevant on iterations after an rtcwake resume, not the
        # very first pass at process startup (that one was never slow).
        log "Waiting ${WAKE_SETTLE}s for resume to settle"
        sleep "$WAKE_SETTLE"

        dump_service_status "after-wake"

        log "--- dmesg tail after wake (diagnostic) ---"
        dmesg 2>/dev/null | tail -n 40 >> "$LOG"
        log "--- end dmesg ---"
    fi
    FIRST_ITERATION=0

    # Guard the connect phase against premature suspend
    start_keep_awake
    set_cpu_performance

    log "Enabling WiFi"
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
    sleep 2

    if ! wait_for_wifid "$WIFID_WAIT_TIMEOUT"; then
        log "wifid unresponsive after wireless enable - forcing restart"
        dump_service_status "pre-forced-restart"
        restart_wifid
        dump_service_status "post-forced-restart"
        wait_for_wifid "$WIFID_WAIT_TIMEOUT"
    fi

    dump_wifi_state "after-wireless-enable"

    # Ask wifid to connect using its own saved profile
    log "Requesting cmConnect $SSID"
    lipc-set-prop com.lab126.wifid cmConnect "$SSID" 2>/dev/null

    # Track real elapsed wall-clock time rather than a loop-iteration
    # count. In the 2026-07-22 log, individual lipc-get-prop calls
    # blocked for 30-90+ seconds while wifid was struggling, so a
    # 1-second sleep per iteration doesn't mean 1 second actually
    # passed - "escalation at i=15" fired 8 minutes in, not 15 seconds.
    # Using date-based elapsed time keeps the escalation thresholds
    # meaningful regardless of how long each individual call blocks.
    CONNECT_START=$(date +%s)
    CONNECT_TIMEOUT=600   # give up on this cycle entirely after 10 min
    ESCALATION_1_AT=60    # re-issue cmConnect after 1 min stuck
    ESCALATION_2_AT=240   # restart the service trio after 4 min stuck
    did_escalation_1=0
    did_escalation_2=0

    while true; do
        NOW=$(date +%s)
        ELAPSED=$((NOW - CONNECT_START))

        STATE=$(lipc_get com.lab126.wifid cmState)
        if echo "$STATE" | grep -q CONNECTED; then
            log "Connected after ${ELAPSED}s"
            break
        fi

        # Escalation step 1: re-issue cmConnect via wifid (not wpa_cli).
        # Cheap and harmless if wifid is just slow.
        if [ "$did_escalation_1" -eq 0 ] && [ "$ELAPSED" -ge "$ESCALATION_1_AT" ]; then
            did_escalation_1=1
            log "Escalation 1 (${ELAPSED}s elapsed): re-issuing cmConnect"
            dump_wifi_state "pre-escalation-1"
            lipc-set-prop com.lab126.wifid cmConnect "$SSID" 2>/dev/null
        fi

        # Escalation step 2 (last resort): restart the wifi service
        # trio outright. NOTE: this used to also try cmDisconnect +
        # cmConnect as an intermediate step, but logs from both
        # 2026-07-21 and 2026-07-22 show cmDisconnect reliably crashing
        # wifid off the lipc bus (immediate lipcErrNoSuchSource) without
        # ever helping it reconnect, and profileCount reading back as 0
        # once it recovers. It has been removed entirely rather than
        # tuned - there's no evidence it ever does anything useful.
        if [ "$did_escalation_2" -eq 0 ] && [ "$ELAPSED" -ge "$ESCALATION_2_AT" ]; then
            did_escalation_2=1
            log "Escalation 2 (${ELAPSED}s elapsed): restarting wifi service trio"
            dump_wifi_state "pre-escalation-2"
            dump_service_status "pre-escalation-2"
            restart_wifid
            wait_for_wifid "$WIFID_WAIT_TIMEOUT"
            dump_wifi_state "post-escalation-2"
            dump_service_status "post-escalation-2"
            lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
            sleep 1
            lipc-set-prop com.lab126.wifid cmConnect "$SSID" 2>/dev/null
        fi

        # Give-up check comes AFTER the escalation checks, not before.
        # In the 2026-07-22 log, a single blocking lipc call let ELAPSED
        # jump straight from ~116s to past 600s, and because this check
        # used to run first, escalation 2 (threshold 240s) never fired
        # at all that cycle - the loop gave up without ever attempting
        # a restart.
        if [ "$ELAPSED" -ge "$CONNECT_TIMEOUT" ]; then
            log "Giving up after ${ELAPSED}s, no connection"
            break
        fi

        sleep 2
    done

    dump_wifi_state "loop-end"
    log "WiFi: $STATE (waited ${ELAPSED}s)"

    # Update weather
    if echo "$STATE" | grep -q CONNECTED; then
        sh "$UPDATE_SCRIPT" 2>/dev/null
        log "Update complete"
    else
        log "No WiFi, using cached image"
        fbink -m -y 28 "No WiFi - showing cached weather"
    fi

    # Display weather
    if [ -s /mnt/us/screensaver/weather.png ]; then
        fbink -k -f -W GC16 -w && fbink -g file=/mnt/us/screensaver/weather.png,w=-2,h=-2 -f -W GC16
        log "Displayed"
    fi

    # Disable WiFi to save power
    lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null

    # Done with the connect/update phase - let the device actually suspend
    stop_keep_awake
    set_cpu_powersave

    # Schedule wake and suspend
    log "Sleeping ${INTERVAL}s"
    rtcwake -d /dev/rtc1 -m no -s $INTERVAL 2>/dev/null
    echo "mem" > /sys/power/state

    log "Woke up"
done
