from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import ssl
import stat
import tempfile
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import UUID


Transport = Callable[[str, str, str | None, ssl.SSLContext], dict[str, Any]]


def _default_transport(
    method: str,
    url: str,
    token: str | None,
    context: ssl.SSLContext,
) -> dict[str, Any]:
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(url, data=b"", headers=headers, method=method)
    try:
        with urlopen(request, timeout=15, context=context) as response:
            value = json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        code = "HTTP_ERROR"
        try:
            body = json.loads(error.read().decode("utf-8"))
            code = body.get("code", code)
        except (UnicodeDecodeError, json.JSONDecodeError):
            pass
        raise RuntimeError(f"서버가 요청을 거부했습니다 ({error.code}, {code})") from error
    except URLError as error:
        raise RuntimeError(f"서버에 연결할 수 없습니다: {error.reason}") from error
    if not isinstance(value, dict):
        raise RuntimeError("서버 응답 형식이 올바르지 않습니다")
    return value


class DeviceApi:
    def __init__(
        self,
        base_url: str,
        ca_cert: Path | None = None,
        transport: Transport = _default_transport,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        if not self.base_url.startswith("https://"):
            raise ValueError("API 기본 URL은 HTTPS를 사용해야 합니다")
        self.context = ssl.create_default_context(cafile=str(ca_cert) if ca_cert else None)
        self.transport = transport

    def enroll(self, bootstrap_token: str) -> dict[str, Any]:
        return self.transport(
            "POST", f"{self.base_url}/api/iot/enrollment", bootstrap_token, self.context
        )

    def rotate(self, operating_token: str) -> dict[str, Any]:
        return self.transport(
            "POST", f"{self.base_url}/api/iot/credentials/rotate",
            operating_token, self.context,
        )

    def registration_code(self, operating_token: str) -> dict[str, Any]:
        return self.transport(
            "POST", f"{self.base_url}/api/iot/registration-codes",
            operating_token, self.context,
        )


def read_secret_file(path: Path) -> str:
    if not path.is_file():
        raise ValueError(f"비밀값 파일이 없습니다: {path}")
    if os.name == "posix" and stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise ValueError(f"비밀값 파일은 그룹이나 다른 사용자가 읽을 수 없어야 합니다: {path}")
    value = path.read_text(encoding="utf-8").strip()
    if not value or "\n" in value or "\r" in value:
        raise ValueError("비밀값 파일에는 토큰 하나만 있어야 합니다")
    return value


def read_environment(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        values[key.strip()] = value
    return values


def update_environment(path: Path, updates: dict[str, str]) -> None:
    for key, value in updates.items():
        if not key or "=" in key or any(char in value for char in "\r\n"):
            raise ValueError("환경 변수 이름 또는 값에 허용되지 않는 문자가 있습니다")

    existing = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    pending = dict(updates)
    output: list[str] = []
    for line in existing:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key in pending:
                output.append(f"{key}={pending.pop(key)}")
                continue
        output.append(line)
    if output and output[-1] != "":
        output.append("")
    output.extend(f"{key}={value}" for key, value in pending.items())

    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write("\n".join(output).rstrip() + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def validate_credential(response: dict[str, Any]) -> dict[str, str]:
    if response.get("purpose") != "OPERATING":
        raise RuntimeError("서버가 운영용 자격증명을 반환하지 않았습니다")
    device_id = str(UUID(str(response["deviceId"])))
    token = response.get("bearerToken")
    expires_at = response.get("expiresAt")
    if not isinstance(token, str) or "." not in token or not isinstance(expires_at, str):
        raise RuntimeError("서버가 반환한 운영용 자격증명이 올바르지 않습니다")
    return {
        "DEVICE_ID": device_id,
        "DEVICE_BEARER_TOKEN": token,
        "DEVICE_CREDENTIAL_EXPIRES_AT": expires_at,
    }


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="William James 기기 등록 및 자격증명 관리")
    value.add_argument("--api-base-url", required=True)
    value.add_argument("--env-file", type=Path, default=Path("/etc/william-james/device-agent.env"))
    value.add_argument("--ca-cert", type=Path)
    commands = value.add_subparsers(dest="command", required=True)
    enroll = commands.add_parser("enroll", help="일회용 bootstrap 토큰을 운영용으로 교환")
    enroll.add_argument("--bootstrap-token-file", type=Path, required=True)
    registration_code = commands.add_parser(
        "registration-code",
        help="2분짜리 사용자 등록 코드 발급",
    )
    registration_code.add_argument(
        "--output-format",
        choices=("text", "json"),
        default="text",
    )
    commands.add_parser("rotate", help="현재 운영용 자격증명 교체")
    return value


def main() -> None:
    args = parser().parse_args()
    api = DeviceApi(args.api_base_url, args.ca_cert)
    if args.command == "enroll":
        response = api.enroll(read_secret_file(args.bootstrap_token_file))
        update_environment(args.env_file, validate_credential(response))
        args.bootstrap_token_file.unlink()
        print(f"기기 등록 완료: {response['deviceId']}; bootstrap 토큰 파일을 삭제했습니다.")
        return

    environment = read_environment(args.env_file)
    token = environment.get("DEVICE_BEARER_TOKEN")
    if not token:
        raise ValueError(f"{args.env_file}에 DEVICE_BEARER_TOKEN이 없습니다")
    if args.command == "rotate":
        response = api.rotate(token)
        update_environment(args.env_file, validate_credential(response))
        print(f"기기 자격증명 교체 완료: {response['deviceId']}")
        return

    response = api.registration_code(token)
    code = response.get("registrationCode")
    expires_at = response.get("expiresAt")
    if not isinstance(code, str) or not isinstance(expires_at, str):
        raise RuntimeError("서버가 반환한 등록 코드가 올바르지 않습니다")
    if args.output_format == "json":
        print(
            json.dumps(
                {
                    "registrationCode": code,
                    "expiresAt": expires_at,
                },
                separators=(",", ":"),
            ),
        )
        return
    print(f"등록 코드: {code}")
    print(f"만료 시각: {expires_at}")


if __name__ == "__main__":
    main()
