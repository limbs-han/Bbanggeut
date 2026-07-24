#!/usr/bin/env bash

# Record one-hour Jetson integration evidence without changing service state.
# Run as root through systemd-run so the test survives SSH disconnection.

set -Eeuo pipefail

DURATION_SECONDS="${1:-3600}"
INTERVAL_SECONDS="${2:-60}"

: "${FFPROBE_PATH:=/usr/bin/ffprobe}"
: "${RECORDING_DIR:=/var/lib/william-james/recordings}"
: "${LOCAL_RTSP_MAIN_URL:=rtsp://127.0.0.1:8554/homecam/main}"
: "${LOCAL_RTSP_AI_URL:=rtsp://127.0.0.1:8554/homecam/ai}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root, preferably with systemd-run" >&2
    exit 1
fi
for value_name in DURATION_SECONDS INTERVAL_SECONDS; do
    value="${!value_name}"
    if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "${value_name} must be a positive integer" >&2
        exit 2
    fi
done
if [[ ! -x "$FFPROBE_PATH" ]]; then
    echo "FFprobe executable not found: ${FFPROBE_PATH}" >&2
    exit 1
fi

units=(
    wj-media-source.service
    wj-mediamtx-local.service
    wj-local-recording.service
    wj-edge-ai-mvp.service
)

recording_bytes() {
    find "$RECORDING_DIR" \
        -maxdepth 1 \
        -type f \
        -name 'homecam-*.ts' \
        -printf '%s\n' 2>/dev/null |
        awk '{ total += $1 } END { printf "%.0f\n", total }'
}

recording_count() {
    find "$RECORDING_DIR" \
        -maxdepth 1 \
        -type f \
        -name 'homecam-*.ts' \
        -printf '.\n' 2>/dev/null |
        wc -l
}

probe_stream() {
    local name="$1"
    local source="$2"
    local started_ms finished_ms elapsed_ms result

    started_ms="$(date +%s%3N)"
    if timeout 12 "$FFPROBE_PATH" \
        -v error \
        -rtsp_transport tcp \
        -select_streams v:0 \
        -show_entries stream=codec_name \
        -of csv=p=0 \
        "$source" >/dev/null 2>&1; then
        result=PASS
    else
        result=FAIL
    fi
    finished_ms="$(date +%s%3N)"
    elapsed_ms=$((finished_ms - started_ms))
    printf 'RTSP name=%s result=%s elapsed_ms=%s\n' \
        "$name" "$result" "$elapsed_ms"
}

sample_system() {
    local now_epoch="$1"
    local sample_index="$2"
    local unit active_state sub_state restarts
    local tegrastats_output tegrastats_status

    printf 'SAMPLE index=%s timestamp=%s elapsed_seconds=%s\n' \
        "$sample_index" \
        "$(date --iso-8601=seconds)" \
        "$((now_epoch - started_epoch))"

    for unit in "${units[@]}"; do
        active_state="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)"
        sub_state="$(systemctl show "$unit" -p SubState --value 2>/dev/null || true)"
        restarts="$(systemctl show "$unit" -p NRestarts --value 2>/dev/null || true)"
        printf 'SERVICE unit=%s active=%s sub=%s restarts=%s\n' \
            "$unit" \
            "${active_state:-unknown}" \
            "${sub_state:-unknown}" \
            "${restarts:-unknown}"
    done

    probe_stream main "$LOCAL_RTSP_MAIN_URL"
    probe_stream ai "$LOCAL_RTSP_AI_URL"

    printf 'RECORDING files=%s bytes=%s\n' \
        "$(recording_count)" \
        "$(recording_bytes)"
    df -B1 --output=size,used,avail,pcent,target "$RECORDING_DIR" |
        tail -n 1 |
        sed 's/^/DISK /'

    ps -eo pid=,etimes=,pcpu=,pmem=,rss=,comm=,args= |
        awk '$6 == "ffmpeg" || $6 == "mediamtx" ||
            ($6 ~ /^python/ &&
             $0 ~ /(wj_device_agent|yolov8_autoframe|yamnet_laughter|laughter_clip_uploader|segment_clip_uploader)/) {
            printf "PROCESS pid=%s elapsed=%s cpu=%s mem_percent=%s rss_kib=%s command=%s args=",
                $1, $2, $3, $4, $5, $6
            for (i = 7; i <= NF; i++) {
                printf "%s%s", $i, (i == NF ? "\n" : " ")
            }
        }'

    if command -v tegrastats >/dev/null 2>&1; then
        set +e
        tegrastats_output="$(timeout 2 tegrastats --interval 1000 2>&1)"
        tegrastats_status="$?"
        set -e
        if [[ -n "$tegrastats_output" ]]; then
            printf '%s\n' "$tegrastats_output" | sed 's/^/TEGRASTATS /'
        fi
        if [[ "$tegrastats_status" -ne 0 && "$tegrastats_status" -ne 124 ]]; then
            printf 'TEGRASTATS_ERROR status=%s\n' "$tegrastats_status"
        fi
    else
        echo "TEGRASTATS unavailable"
    fi
}

started_epoch="$(date +%s)"
finished_epoch=$((started_epoch + DURATION_SECONDS))
initial_recording_bytes="$(recording_bytes)"
sample_index=0

printf 'SOAK_START timestamp=%s duration_seconds=%s interval_seconds=%s recording_bytes=%s\n' \
    "$(date --iso-8601=seconds)" \
    "$DURATION_SECONDS" \
    "$INTERVAL_SECONDS" \
    "$initial_recording_bytes"

while true; do
    now_epoch="$(date +%s)"
    sample_system "$now_epoch" "$sample_index"
    if (( now_epoch >= finished_epoch )); then
        break
    fi

    sample_index=$((sample_index + 1))
    next_sample_epoch=$((started_epoch + sample_index * INTERVAL_SECONDS))
    if (( next_sample_epoch > finished_epoch )); then
        next_sample_epoch="$finished_epoch"
    fi
    now_after_sample="$(date +%s)"
    sleep_seconds=$((next_sample_epoch - now_after_sample))
    if (( sleep_seconds > 0 )); then
        sleep "$sleep_seconds"
    fi
done

final_recording_bytes="$(recording_bytes)"
printf 'SOAK_COMPLETE timestamp=%s samples=%s recording_bytes=%s recording_delta_bytes=%s\n' \
    "$(date --iso-8601=seconds)" \
    "$((sample_index + 1))" \
    "$final_recording_bytes" \
    "$((final_recording_bytes - initial_recording_bytes))"
