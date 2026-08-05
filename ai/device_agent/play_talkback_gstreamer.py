#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path
from urllib.parse import unquote, urlsplit, urlunsplit


def build_command(url: str, output_device: str) -> list[str]:
    parsed = urlsplit(url)
    if parsed.scheme not in {"rtsp", "rtsps"}:
        raise ValueError("talkback URL must use RTSP or RTSPS")
    if not parsed.hostname or parsed.username is None or parsed.password is None:
        raise ValueError("talkback URL must contain RTSP credentials")

    hostname = parsed.hostname
    if ":" in hostname and not hostname.startswith("["):
        hostname = f"[{hostname}]"
    netloc = hostname if parsed.port is None else f"{hostname}:{parsed.port}"
    sanitized_url = urlunsplit(
        (parsed.scheme, netloc, parsed.path, parsed.query, parsed.fragment)
    )

    return [
        "/usr/bin/gst-launch-1.0",
        "-q",
        "rtspsrc",
        f"location={sanitized_url}",
        f"user-id={unquote(parsed.username)}",
        f"user-pw={unquote(parsed.password)}",
        "protocols=tcp",
        "latency=100",
        "!",
        "rtpopusdepay",
        "!",
        "opusdec",
        "!",
        "audioconvert",
        "!",
        "audioresample",
        "!",
        "alsasink",
        f"device={output_device}",
        "sync=false",
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("--output-device", default="default")
    args = parser.parse_args()

    runtime_home = Path("/tmp/wj-talkback-gstreamer")
    runtime_home.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.environ["HOME"] = str(runtime_home)
    os.environ["XDG_CACHE_HOME"] = str(runtime_home / ".cache")
    os.environ["XDG_CONFIG_HOME"] = str(runtime_home / ".config")
    Path(os.environ["XDG_CACHE_HOME"]).mkdir(mode=0o700, exist_ok=True)
    Path(os.environ["XDG_CONFIG_HOME"]).mkdir(mode=0o700, exist_ok=True)

    command = build_command(args.url, args.output_device)
    os.execv(command[0], command)


if __name__ == "__main__":
    main()
