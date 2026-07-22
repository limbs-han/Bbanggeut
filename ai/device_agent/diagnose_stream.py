#!/usr/bin/env python3
"""Run the configured FFmpeg publisher with visible diagnostics.

This script is intended to be executed as the device-agent service user while
the service itself is stopped.  It publishes to a temporary MediaMTX path and
then verifies that the path can be read back through the local SSH tunnel.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from wj_device_agent.config import AgentConfig


def main() -> int:
    config = AgentConfig.from_environment()
    stream_id = f"diagnose-{uuid.uuid4()}"
    publish_url = config.publish_url_template.format(stream_id=stream_id)
    parsed_url = urlsplit(publish_url)

    # Diagnostics may expose an output URL in FFmpeg messages.  Only allow the
    # credential-free local tunnel endpoint used by the production agent.
    if parsed_url.hostname not in {"127.0.0.1", "localhost"} or parsed_url.username:
        print("REFUSED: RTSP publish URL is not a credential-free local tunnel URL")
        return 2

    command = [
        config.ffmpeg_path,
        "-hide_banner",
        "-nostdin",
        "-loglevel",
        "info",
        *config.ffmpeg_input_args,
        *config.ffmpeg_audio_input_args,
        "-map",
        "0:v:0",
    ]
    if config.ffmpeg_audio_from_primary_input:
        command.extend(["-map", "0:a:0"])
    elif config.ffmpeg_audio_input_args:
        command.extend(["-map", "1:a:0"])
    command.extend(config.ffmpeg_video_args)
    if config.ffmpeg_audio_from_primary_input or config.ffmpeg_audio_input_args:
        command.extend(config.ffmpeg_audio_args)
    else:
        command.append("-an")
    command.extend(["-f", "rtsp", "-rtsp_transport", "tcp", publish_url])

    print(f"DIAGNOSTIC_STREAM_ID={stream_id}", flush=True)
    print("Starting the exact configured FFmpeg publisher for up to 15 seconds...", flush=True)
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL)

    try:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            return_code = process.poll()
            if return_code is not None:
                print(f"RESULT=FFMPEG_EXITED RETURN_CODE={return_code}")
                return 1
            time.sleep(0.5)

        ffprobe_path = str(Path(config.ffmpeg_path).with_name("ffprobe"))
        if not Path(ffprobe_path).exists():
            ffprobe_path = shutil.which("ffprobe") or ""
        if not ffprobe_path:
            print("RESULT=FFMPEG_STAYED_RUNNING (ffprobe is unavailable)")
            return 0

        print("FFmpeg stayed running; probing the published RTSP path...", flush=True)
        probe = subprocess.run(
            [
                ffprobe_path,
                "-v",
                "error",
                "-rtsp_transport",
                "tcp",
                "-show_entries",
                "stream=index,codec_type,codec_name",
                "-of",
                "compact=p=0:nk=1",
                publish_url,
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        if probe.stdout.strip():
            print(probe.stdout.strip())
        if probe.stderr.strip():
            print(probe.stderr.strip(), file=sys.stderr)
        if probe.returncode == 0:
            print("RESULT=RTSP_PUBLISH_AND_READ_OK")
            return 0
        print(f"RESULT=RTSP_PROBE_FAILED RETURN_CODE={probe.returncode}")
        return 1
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
