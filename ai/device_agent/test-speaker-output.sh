#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./test-speaker-output.sh [ALSA_DEVICE] [DURATION_SECONDS]
  ./test-speaker-output.sh --list

Examples:
  bash ./test-speaker-output.sh
  bash ./test-speaker-output.sh plughw:CARD=Device,DEV=0 3

ALSA_DEVICE defaults to TALKBACK_OUTPUT_DEVICE, then "default".
SPEAKER_TEST_LEVEL defaults to 0.25, approximately -12 dBFS. Use a value
between 0 and 1 to adjust the signal level; 1.0 is approximately 0 dBFS.
The generated mono tone is duplicated to both stereo channels so a single
speaker connected to either LOUT or ROUT can be tested.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--list" ]]; then
    if ! command -v aplay >/dev/null 2>&1; then
        echo "aplay is required. Install alsa-utils first." >&2
        exit 1
    fi
    echo "=== ALSA playback hardware ==="
    aplay -l
    echo
    echo "=== ALSA playback device names ==="
    aplay -L
    exit 0
fi

DEVICE="${1:-${TALKBACK_OUTPUT_DEVICE:-default}}"
DURATION_SECONDS="${2:-3}"
FREQUENCY_HZ="${SPEAKER_TEST_FREQUENCY_HZ:-880}"
SIGNAL_LEVEL="${SPEAKER_TEST_LEVEL:-0.25}"
FFMPEG_PATH="${FFMPEG_PATH:-/usr/bin/ffmpeg}"
MIXER_CARD=""

if [[ "$DEVICE" =~ CARD=([^,]+) ]]; then
    MIXER_CARD="${BASH_REMATCH[1]}"
fi

if [[ ! "$DURATION_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "DURATION_SECONDS must be a positive number: ${DURATION_SECONDS}" >&2
    exit 2
fi
if [[ ! "$FREQUENCY_HZ" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "SPEAKER_TEST_FREQUENCY_HZ must be a positive number: ${FREQUENCY_HZ}" >&2
    exit 2
fi
if [[ ! "$SIGNAL_LEVEL" =~ ^(0([.][0-9]+)?|1([.]0+)?)$ ]]; then
    echo "SPEAKER_TEST_LEVEL must be between 0 and 1: ${SIGNAL_LEVEL}" >&2
    exit 2
fi

if [[ "$FFMPEG_PATH" == */* ]]; then
    if [[ ! -x "$FFMPEG_PATH" ]]; then
        echo "FFmpeg is not executable: ${FFMPEG_PATH}" >&2
        exit 1
    fi
elif ! command -v "$FFMPEG_PATH" >/dev/null 2>&1; then
    echo "FFmpeg is not available: ${FFMPEG_PATH}" >&2
    exit 1
fi

if [[ -n "$MIXER_CARD" ]] && command -v amixer >/dev/null 2>&1; then
    if amixer -c "$MIXER_CARD" sset Speaker 100% unmute >/dev/null 2>&1; then
        echo "ALSA mixer  : Speaker 100% (card ${MIXER_CARD})"
    else
        echo "Warning: could not set the Speaker mixer on card ${MIXER_CARD}." >&2
    fi
fi

cat <<EOF
ALSA device : ${DEVICE}
Duration    : ${DURATION_SECONDS}s
Frequency   : ${FREQUENCY_HZ}Hz
Signal level: ${SIGNAL_LEVEL} (1.0 is approximately 0 dBFS)

WARNING: the test signal defaults to approximately -12 dBFS.
Keep earphones out of your ears and the PAM8403 knob near minimum for the first run.
Starting the test tone in 2 seconds. Press Ctrl+C to cancel.
EOF
sleep 2

if ! "$FFMPEG_PATH" \
    -hide_banner -nostdin -loglevel warning \
    -f lavfi \
    -i "sine=frequency=${FREQUENCY_HZ}:sample_rate=48000:duration=${DURATION_SECONDS}" \
    -filter:a "volume=8*${SIGNAL_LEVEL}" \
    -ac 2 -ar 48000 \
    -f alsa "$DEVICE"; then
    cat >&2 <<EOF

Speaker test failed for ALSA device: ${DEVICE}
Run "bash $0 --list" and retry with a device from aplay -L, for example:
  bash $0 plughw:CARD=Device,DEV=0 3
EOF
    exit 1
fi

echo "Speaker test completed."
