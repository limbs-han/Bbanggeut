from __future__ import annotations

import argparse
from getpass import getpass
import os
from pathlib import Path
import stat
import re
from urllib.parse import quote

from .provision import read_environment, read_secret_file, update_environment


JETSON_USERNAME_KEY = "MEDIAMTX_JETSON_PUBLISH_USER"
JETSON_PASSWORD_KEY = "MEDIAMTX_JETSON_PUBLISH_PASSWORD"


def build_publish_url(
    username: str,
    password: str,
    host: str,
    port: int,
    scheme: str = "rtsps",
) -> str:
    username = username.strip()
    host = host.strip()
    if not username:
        raise ValueError("MediaMTX publish username is required")
    if not password:
        raise ValueError("MediaMTX publish password is required")
    if (
        not host
        or any(character.isspace() for character in host)
        or any(character in host for character in "/@:")
    ):
        raise ValueError("Media host must be a DNS name or IPv4 address without a port")
    if not 1 <= port <= 65535:
        raise ValueError("Media port must be between 1 and 65535")
    if scheme not in {"rtsp", "rtsps"}:
        raise ValueError("Media scheme must be rtsp or rtsps")
    return (
        f"{scheme}://{quote(username, safe='')}:{quote(password, safe='')}"
        f"@{host}:{port}/live/{{stream_id}}"
    )


def read_credentials_environment(path: Path) -> tuple[str, str]:
    if not path.is_file():
        raise ValueError(f"MediaMTX credentials file does not exist: {path}")
    if os.name == "posix" and stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise ValueError(
            f"MediaMTX credentials file must not be readable by group or others: {path}"
        )
    values = read_environment(path)
    username = values.get(JETSON_USERNAME_KEY, "").strip()
    password = values.get(JETSON_PASSWORD_KEY, "")
    if not username or not password:
        raise ValueError(
            f"{path} must contain {JETSON_USERNAME_KEY} and {JETSON_PASSWORD_KEY}"
        )
    if any(character in username + password for character in "\r\n"):
        raise ValueError("MediaMTX credentials must each fit on one line")
    return username, password


def read_sha256_fingerprint(path: Path) -> str:
    if not path.is_file():
        raise ValueError(f"CA fingerprint file does not exist: {path}")
    value = path.read_text(encoding="utf-8").strip().upper()
    compact = value.replace(":", "")
    if not re.fullmatch(r"[0-9A-F]{64}", compact):
        raise ValueError("CA fingerprint file must contain one SHA-256 fingerprint")
    return ":".join(compact[index:index + 2] for index in range(0, 64, 2))


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(
        description="Configure an authenticated MediaMTX publish URL without printing secrets."
    )
    value.add_argument(
        "--env-file",
        type=Path,
        default=Path("/etc/william-james/device-agent.env"),
    )
    value.add_argument("--host", default="i15e201.p.ssafy.io")
    value.add_argument("--port", type=int, default=8322)
    value.add_argument("--scheme", choices=("rtsp", "rtsps"), default="rtsps")
    value.add_argument("--username")
    value.add_argument(
        "--ca-cert",
        type=Path,
        help="installed MediaMTX CA certificate path",
    )
    value.add_argument(
        "--ca-fingerprint-file",
        type=Path,
        help="file containing the independently verified CA SHA-256 fingerprint",
    )
    input_mode = value.add_mutually_exclusive_group()
    input_mode.add_argument(
        "--credentials-env",
        type=Path,
        help=(
            "mode-600 env file containing "
            f"{JETSON_USERNAME_KEY} and {JETSON_PASSWORD_KEY}"
        ),
    )
    input_mode.add_argument(
        "--password-file",
        type=Path,
        help="mode-600 file containing only the MediaMTX publish password",
    )
    return value


def main() -> None:
    args = parser().parse_args()
    if bool(args.ca_cert) != bool(args.ca_fingerprint_file):
        raise ValueError("--ca-cert and --ca-fingerprint-file must be supplied together")
    if args.ca_cert and not args.ca_cert.is_file():
        raise ValueError(f"MediaMTX CA certificate does not exist: {args.ca_cert}")
    if args.credentials_env:
        if args.username:
            raise ValueError("--username cannot be combined with --credentials-env")
        username, password = read_credentials_environment(args.credentials_env)
    else:
        username = args.username or input("MediaMTX publish username: ").strip()
        password = (
            read_secret_file(args.password_file)
            if args.password_file
            else getpass("MediaMTX publish password: ")
        )

    publish_url = build_publish_url(
        username,
        password,
        args.host,
        args.port,
        args.scheme,
    )
    updates = {"MEDIA_PUBLISH_URL_TEMPLATE": publish_url}
    if args.ca_cert and args.ca_fingerprint_file:
        updates.update({
            "MEDIA_TLS_CA_CERT": str(args.ca_cert),
            "MEDIA_TLS_CA_SHA256": read_sha256_fingerprint(args.ca_fingerprint_file),
        })
    update_environment(args.env_file, updates)
    print(
        "Configured MediaMTX publish endpoint: "
        f"{args.scheme}://{args.host}:{args.port}/live/{{stream_id}} ({args.env_file})"
    )


if __name__ == "__main__":
    main()
