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
        raise RuntimeError(f"Server rejected the request ({error.code}, {code})") from error
    except URLError as error:
        raise RuntimeError(f"Could not reach the server: {error.reason}") from error
    if not isinstance(value, dict):
        raise RuntimeError("Server returned an invalid response")
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
            raise ValueError("API base URL must use HTTPS")
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
        raise ValueError(f"Secret file does not exist: {path}")
    if os.name == "posix" and stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise ValueError(f"Secret file must not be readable by group/others: {path}")
    value = path.read_text(encoding="utf-8").strip()
    if not value or "\n" in value or "\r" in value:
        raise ValueError("Secret file must contain exactly one token")
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
            raise ValueError("Environment key/value contains an invalid character")

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
        raise RuntimeError("Server did not return an operating credential")
    device_id = str(UUID(str(response["deviceId"])))
    token = response.get("bearerToken")
    expires_at = response.get("expiresAt")
    if not isinstance(token, str) or "." not in token or not isinstance(expires_at, str):
        raise RuntimeError("Server returned an invalid operating credential")
    return {
        "DEVICE_ID": device_id,
        "DEVICE_BEARER_TOKEN": token,
        "DEVICE_CREDENTIAL_EXPIRES_AT": expires_at,
    }


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="Enroll and manage a William James device")
    value.add_argument("--api-base-url", required=True)
    value.add_argument("--env-file", type=Path, default=Path("/etc/william-james/device-agent.env"))
    value.add_argument("--ca-cert", type=Path)
    commands = value.add_subparsers(dest="command", required=True)
    enroll = commands.add_parser("enroll", help="exchange a one-use bootstrap token")
    enroll.add_argument("--bootstrap-token-file", type=Path, required=True)
    commands.add_parser("registration-code", help="issue a two-minute user claim code")
    commands.add_parser("rotate", help="replace the current operating credential")
    return value


def main() -> None:
    args = parser().parse_args()
    api = DeviceApi(args.api_base_url, args.ca_cert)
    if args.command == "enroll":
        response = api.enroll(read_secret_file(args.bootstrap_token_file))
        update_environment(args.env_file, validate_credential(response))
        args.bootstrap_token_file.unlink()
        print(f"Enrolled device {response['deviceId']}; bootstrap token file deleted.")
        return

    environment = read_environment(args.env_file)
    token = environment.get("DEVICE_BEARER_TOKEN")
    if not token:
        raise ValueError(f"DEVICE_BEARER_TOKEN is missing from {args.env_file}")
    if args.command == "rotate":
        response = api.rotate(token)
        update_environment(args.env_file, validate_credential(response))
        print(f"Rotated credential for device {response['deviceId']}.")
        return

    response = api.registration_code(token)
    code = response.get("registrationCode")
    expires_at = response.get("expiresAt")
    if not isinstance(code, str) or not isinstance(expires_at, str):
        raise RuntimeError("Server returned an invalid registration code")
    print(f"Registration code: {code}")
    print(f"Expires at: {expires_at}")


if __name__ == "__main__":
    main()
