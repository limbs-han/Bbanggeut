#!/usr/bin/env bash

# Delete only completed homecam segments older than the configured retention.
# The marker and path checks prevent an accidental broad filesystem deletion.

set -Eeuo pipefail

: "${RECORDING_DIR:=/var/lib/william-james/recordings}"
: "${RECORDING_RETENTION_DAYS:=7}"
: "${RECORDING_MAX_GIB:=8}"

if [[ "$RECORDING_DIR" != /* ]]; then
    echo "RECORDING_DIR must be absolute" >&2
    exit 2
fi
case "$RECORDING_DIR" in
    /|/bin|/boot|/dev|/etc|/home|/opt|/root|/run|/srv|/tmp|/usr|/var|/var/lib)
        echo "Refusing unsafe RECORDING_DIR: ${RECORDING_DIR}" >&2
        exit 2
        ;;
esac
if ! [[ "$RECORDING_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]]; then
    echo "RECORDING_RETENTION_DAYS must be a positive integer" >&2
    exit 2
fi
if ! [[ "$RECORDING_MAX_GIB" =~ ^[1-9][0-9]*$ ]]; then
    echo "RECORDING_MAX_GIB must be a positive integer" >&2
    exit 2
fi
if [[ ! -f "${RECORDING_DIR}/.homecam-recordings" ]]; then
    echo "Recording safety marker is missing: ${RECORDING_DIR}/.homecam-recordings" >&2
    exit 1
fi

retention_minutes=$((RECORDING_RETENTION_DAYS * 24 * 60))
find "$RECORDING_DIR" \
    -maxdepth 1 \
    -type f \
    -name 'homecam-*.ts' \
    -mmin "+${retention_minutes}" \
    -print \
    -delete

recording_bytes() {
    find "$RECORDING_DIR" \
        -maxdepth 1 \
        -type f \
        -name 'homecam-*.ts' \
        -printf '%s\n' |
        awk '{ total += $1 } END { printf "%.0f\n", total }'
}

maximum_bytes=$((RECORDING_MAX_GIB * 1024 * 1024 * 1024))
current_bytes="$(recording_bytes)"

while (( current_bytes > maximum_bytes )); do
    oldest_segment="$(
        find "$RECORDING_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'homecam-*.ts' \
            -mmin +2 \
            -printf '%T@ %p\n' |
            sort -n |
            sed -n '1{s/^[^ ]* //;p;}'
    )"

    if [[ -z "$oldest_segment" ]]; then
        echo "Recording usage exceeds ${RECORDING_MAX_GIB} GiB, but no completed segment can be pruned" >&2
        exit 1
    fi
    case "$oldest_segment" in
        "$RECORDING_DIR"/homecam-*.ts)
            ;;
        *)
            echo "Refusing unexpected recording path: ${oldest_segment}" >&2
            exit 1
            ;;
    esac

    echo "Pruning oldest completed segment to enforce ${RECORDING_MAX_GIB} GiB limit: ${oldest_segment}"
    rm -f -- "$oldest_segment"
    current_bytes="$(recording_bytes)"
done

printf 'Recording usage: %s bytes / %s bytes (%s GiB limit)\n' \
    "$current_bytes" "$maximum_bytes" "$RECORDING_MAX_GIB"
df -h "$RECORDING_DIR"
