from __future__ import annotations

import argparse
from getpass import getpass
from pathlib import Path
from urllib.parse import quote

from .provision import read_secret_file, update_environment


def build_publish_url(username: str, password: str, host: str, port: int) -> str:
    username = username.strip()
    host = host.strip()
    if not username:
        raise ValueError("Media publish username is required")
    if not password:
        raise ValueError("Media publish password is required")
    if (
        not host
        or any(character.isspace() for character in host)
        or any(character in host for character in "/@:")
    ):
        raise ValueError("Media host must be a DNS name or IPv4 address without a port")
    if not 1 <= port <= 65535:
        raise ValueError("Media port must be between 1 and 65535")
    return (
        f"rtsps://{quote(username, safe='')}:{quote(password, safe='')}"
        f"@{host}:{port}/live/{{stream_id}}"
    )


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(
        description="Configure the direct RTSPS publisher without exposing its password"
    )
    value.add_argument(
        "--env-file",
        type=Path,
        default=Path("/etc/william-james/device-agent.env"),
    )
    value.add_argument("--host", default="i15e201.p.ssafy.io")
    value.add_argument("--port", type=int, default=8322)
    value.add_argument("--username")
    value.add_argument(
        "--password-file",
        type=Path,
        help="Mode-600 file containing only the MediaMTX publish password",
    )
    return value


def main() -> None:
    args = parser().parse_args()
    username = args.username or input("MediaMTX publish username: ").strip()
    password = (
        read_secret_file(args.password_file)
        if args.password_file
        else getpass("MediaMTX publish password: ")
    )
    publish_url = build_publish_url(username, password, args.host, args.port)
    update_environment(args.env_file, {"MEDIA_PUBLISH_URL_TEMPLATE": publish_url})
    print(
        "Configured direct RTSPS publishing to "
        f"{args.host}:{args.port}/live/{{stream_id}} in {args.env_file}."
    )


if __name__ == "__main__":
    main()
