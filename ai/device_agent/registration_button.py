from __future__ import annotations

import json
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"Missing required environment variable: {name}")
    return value


def main() -> int:
    try:
        base_url = os.environ.get("API_BASE_URL", "https://i15e201.p.ssafy.io").rstrip("/")
        token = required("DEVICE_BEARER_TOKEN")
        request = Request(
            f"{base_url}/api/iot/registration-codes",
            data=b"",
            method="POST",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
                "Content-Length": "0",
            },
        )
        with urlopen(request, timeout=10) as response:
            body = json.load(response)
        code = body["registrationCode"]
        expires_at = body["expiresAt"]
        print("\n=== APP REGISTRATION CODE ===")
        print(code)
        print(f"Expires at: {expires_at}")
        print("Enter this code in App > Settings > Connect new device.\n")
        return 0
    except HTTPError as error:
        try:
            body = json.loads(error.read().decode("utf-8"))
            code = body.get("code", "HTTP_ERROR")
        except (UnicodeDecodeError, json.JSONDecodeError):
            code = "HTTP_ERROR"
        print(f"Registration request failed: {error.code} {code}", file=sys.stderr)
    except (URLError, TimeoutError) as error:
        print(f"Could not reach the backend: {error.reason}", file=sys.stderr)
    except (KeyError, ValueError) as error:
        print(str(error), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
