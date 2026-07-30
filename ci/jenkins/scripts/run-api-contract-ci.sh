#!/usr/bin/env bash
set -euo pipefail

# openapi.yaml 은 손으로 유지하는 계약이라, 컨트롤러에 경로를 추가하고 계약을
# 고치지 않아도 아무것도 막지 않았습니다. 유일한 lint 가 GitHub Actions
# 워크플로에 있었는데 이 저장소는 GitLab 이라 한 번도 실행되지 않았습니다.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${repo_root}"

echo "== 컨트롤러와 OpenAPI 계약 대조 =="
python3 "자료/tools/check_api_spec_coverage.py"

echo
echo "== OpenAPI 문법 검사 =="
if command -v npx >/dev/null 2>&1; then
  npx --yes @redocly/cli@2.39.0 lint "자료/api/openapi.yaml"
else
  cat >&2 <<'WARNING'
================================================================
경고: npx 를 찾을 수 없어 Redocly lint 를 건너뜁니다.
      경로 누락 검사는 그대로 수행했지만, 계약 자체의 문법 오류는
      이 빌드에서 검증되지 않았습니다.

      Agent 에 Node 를 설치하면 해결됩니다.
================================================================
WARNING
fi
