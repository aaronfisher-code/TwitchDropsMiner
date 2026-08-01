#!/bin/sh
set -eu

display="${DISPLAY:-:99}"
width="${DISPLAY_WIDTH:-1280}"
height="${DISPLAY_HEIGHT:-800}"
depth="${DISPLAY_DEPTH:-24}"
data_dir="${TDM_DATA_DIR:-/data}"
runtime_dir="${XDG_RUNTIME_DIR:-/tmp/tdm-runtime}"

case "${width}x${height}x${depth}" in
    *[!0-9x]*)
        echo "DISPLAY_WIDTH, DISPLAY_HEIGHT, and DISPLAY_DEPTH must be numeric" >&2
        exit 2
        ;;
esac

mkdir -p "${data_dir}" "${runtime_dir}"
chmod 0700 "${runtime_dir}"

export DISPLAY="${display}"
export XDG_RUNTIME_DIR="${runtime_dir}"
export XDG_CONFIG_HOME="${data_dir}/.config"
export XDG_CACHE_HOME="${data_dir}/.cache"

desktop_pids=""
app_pid=""

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [ -n "${app_pid}" ]; then
        kill -TERM "${app_pid}" 2>/dev/null || true
        wait "${app_pid}" 2>/dev/null || true
    fi
    if [ -n "${desktop_pids}" ]; then
        kill -TERM ${desktop_pids} 2>/dev/null || true
        wait ${desktop_pids} 2>/dev/null || true
    fi
    exit "${status}"
}
trap cleanup EXIT INT TERM

Xvfb "${display}" -screen 0 "${width}x${height}x${depth}" -nolisten tcp &
desktop_pids="$!"

ready=0
attempt=0
while [ "${attempt}" -lt 50 ]; do
    if xdpyinfo -display "${display}" >/dev/null 2>&1; then
        ready=1
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ "${ready}" -ne 1 ]; then
    echo "The virtual X display did not become ready" >&2
    exit 1
fi

dbus-launch --exit-with-session openbox-session >/tmp/openbox.log 2>&1 &
desktop_pids="${desktop_pids} $!"

if [ -n "${VNC_PASSWORD:-}" ]; then
    password_file="${runtime_dir}/vnc.pass"
    x11vnc -storepasswd "${VNC_PASSWORD}" "${password_file}" >/dev/null
    x11vnc -display "${display}" -forever -shared -rfbport 5900 \
        -rfbauth "${password_file}" -noxdamage >/tmp/x11vnc.log 2>&1 &
else
    echo "Warning: VNC_PASSWORD is unset; access is protected only by the published port binding." >&2
    x11vnc -display "${display}" -forever -shared -rfbport 5900 \
        -nopw -noxdamage >/tmp/x11vnc.log 2>&1 &
fi
desktop_pids="${desktop_pids} $!"

websockify --web=/usr/share/novnc/ 6080 localhost:5900 >/tmp/websockify.log 2>&1 &
desktop_pids="${desktop_pids} $!"

python /app/main.py "$@" &
app_pid=$!
set +e
wait "${app_pid}"
app_status=$?
set -e
app_pid=""
if [ "${app_status}" -ne 0 ]; then
    echo "Twitch Drops Miner exited with status ${app_status}." >&2
    if [ "${app_status}" -eq 3 ]; then
        echo "The application data lock could not be acquired; check for another container using /data." >&2
    fi
    for service_log in /tmp/openbox.log /tmp/x11vnc.log /tmp/websockify.log; do
        if [ -s "${service_log}" ]; then
            echo "--- ${service_log} ---" >&2
            tail -n 50 "${service_log}" >&2
        fi
    done
fi
exit "${app_status}"
