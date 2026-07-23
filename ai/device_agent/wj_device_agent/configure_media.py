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
        raise ValueError("MediaMTX 송출 사용자 이름이 필요합니다")
    if not password:
        raise ValueError("MediaMTX 송출 비밀번호가 필요합니다")
    if (
        not host
        or any(character.isspace() for character in host)
        or any(character in host for character in "/@:")
    ):
        raise ValueError("미디어 호스트에는 포트를 제외한 DNS 이름 또는 IPv4 주소만 입력해야 합니다")
    if not 1 <= port <= 65535:
        raise ValueError("미디어 포트는 1에서 65535 사이여야 합니다")
    return (
        f"rtsps://{quote(username, safe='')}:{quote(password, safe='')}"
        f"@{host}:{port}/live/{{stream_id}}"
    )


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(
        description="비밀번호를 노출하지 않고 직접 RTSPS 송출 주소를 설정합니다"
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
        help="MediaMTX 송출 비밀번호만 들어 있는 권한 600 파일",
    )
    return value


def main() -> None:
    args = parser().parse_args()
    username = args.username or input("MediaMTX 송출 사용자 이름: ").strip()
    password = (
        read_secret_file(args.password_file)
        if args.password_file
        else getpass("MediaMTX 송출 비밀번호: ")
    )
    publish_url = build_publish_url(username, password, args.host, args.port)
    update_environment(args.env_file, {"MEDIA_PUBLISH_URL_TEMPLATE": publish_url})
    print(
        "직접 RTSPS 송출 주소를 설정했습니다: "
        f"{args.host}:{args.port}/live/{{stream_id}} ({args.env_file})"
    )


if __name__ == "__main__":
    main()
