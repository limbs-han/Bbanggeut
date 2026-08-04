#!/usr/bin/env python3
"""Fail when a Spring controller route is missing from the OpenAPI contract.

`openapi.yaml` is written by hand, so nothing forces it to keep up with the
controllers. The Memory Vault migration shipped seven endpoints that never
reached the contract and no check noticed, because the only lint lived in a
GitHub Actions workflow that this GitLab repository never runs.

Standard library only: the CI agents are not guaranteed to have PyYAML or
Node, and a contract check that silently skips itself is worse than none.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Routes that are deliberately absent from the published contract.
# Add to this only with a reason — an empty reason is a silent regression.
UNDOCUMENTED_ON_PURPOSE = {
    "/internal/admin/devices":
        "내부 관리자 전용. 키 불일치·비-loopback을 404로 위장하므로 공개 계약에 싣지 않는다.",
    "/internal/admin/devices/{deviceId}/credentials":
        "위와 같은 내부 관리자 전용 경로.",
    "/internal/admin/devices/{deviceId}/credentials/rotate":
        "위와 같은 내부 관리자 전용 경로.",
    "/api/iot/enrollment":
        "기기 credential 전용 부트스트랩 교환. 앱 계약이 아니라 기기 프로비저닝 절차 문서가 기준이다.",
    "/api/iot/credentials/rotate":
        "위와 같은 기기 credential 전용 경로.",
    "/api/live/introspect":
        "미디어 서버가 호출하는 내부 검증 엔드포인트. 앱 계약이 아니다.",
    "/api/editor/events":
        "editor-api가 서비스 토큰(iss=wj-editor)으로 호출하는 서버 간 이벤트 승격"
        " 엔드포인트. 앱 계약이 아니라 editor-api 연동 문서가 기준이다.",
}

MAPPING = re.compile(
    r"@(Get|Post|Put|Delete|Patch)Mapping\b"
    r'(?:\(\s*(?:value\s*=\s*)?(?:"([^"]*)")?)?'
)
CLASS_MAPPING = re.compile(r'@RequestMapping\(\s*"([^"]+)"')
PATH_VARIABLE = re.compile(r"\{(\w+)[^}]*\}")


def spec_paths(spec_file: Path) -> set[str]:
    """Read the top-level keys of the `paths:` block without a YAML parser."""
    found: set[str] = set()
    in_paths = False
    for line in spec_file.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[:1].isspace():
            in_paths = line.startswith("paths:")
            continue
        if in_paths:
            match = re.match(r"^  (/\S*?):\s*$", line)
            if match:
                found.add(match.group(1))
    return found


def controller_paths(root: Path) -> dict[str, set[str]]:
    found: dict[str, set[str]] = {}
    pattern = "backend/server/src/main/java/**/*Controller.java"
    for java in root.glob(pattern):
        source = java.read_text(encoding="utf-8")
        class_mapping = CLASS_MAPPING.search(source)
        base = class_mapping.group(1) if class_mapping else ""
        for verb, sub in MAPPING.findall(source):
            route = (base + (sub or "")) or base
            if route.startswith(("/api", "/internal")):
                key = PATH_VARIABLE.sub(r"{\1}", route)
                found.setdefault(key, set()).add(verb.lower())
    return found


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    spec_file = root / "자료" / "api" / "openapi.yaml"
    if not spec_file.is_file():
        print(f"OpenAPI 파일을 찾을 수 없습니다: {spec_file}", file=sys.stderr)
        return 2

    documented = spec_paths(spec_file)
    if not documented:
        print("openapi.yaml에서 paths를 하나도 읽지 못했습니다. 형식이 바뀌었는지 확인하세요.",
              file=sys.stderr)
        return 2

    routes = controller_paths(root)
    if not routes:
        print("컨트롤러에서 경로를 하나도 읽지 못했습니다. 검사 대상 경로를 확인하세요.",
              file=sys.stderr)
        return 2

    missing = sorted(
        route for route in routes
        if route not in documented and route not in UNDOCUMENTED_ON_PURPOSE
    )
    stale = sorted(
        route for route in UNDOCUMENTED_ON_PURPOSE
        if route not in routes
    )

    print(f"컨트롤러 경로 {len(routes)}개, 계약에 기재된 경로 {len(documented)}개, "
          f"의도적 제외 {len(UNDOCUMENTED_ON_PURPOSE)}개")

    if stale:
        print("\n다음 경로는 이제 컨트롤러에 없습니다. 제외 목록에서 지우세요:", file=sys.stderr)
        for route in stale:
            print(f"  - {route}", file=sys.stderr)

    if missing:
        print("\n다음 경로가 자료/api/openapi.yaml에 없습니다:", file=sys.stderr)
        for route in missing:
            verbs = ", ".join(sorted(routes[route]))
            print(f"  - {route}  ({verbs})", file=sys.stderr)
        print("\n경로를 추가했다면 계약도 같은 MR에서 갱신하세요. 의도적으로 공개하지 "
              "않는 경로라면 이 스크립트의 UNDOCUMENTED_ON_PURPOSE에 사유와 함께 "
              "추가하세요.", file=sys.stderr)

    if missing or stale:
        return 1

    print("계약과 컨트롤러가 일치합니다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
