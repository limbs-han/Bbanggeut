#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
validator="${repository_root}/ci/jenkins/server/deploy/wj-deploy-backend"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

if grep -q '/usr/bin/jar' "${validator}"; then
  echo "배포 래퍼는 운영 JRE에 없는 JDK jar 명령에 의존하면 안 됩니다." >&2
  exit 1
fi

python3 - "${test_root}" <<'PY'
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])

with zipfile.ZipFile(root / "valid.jar", "w") as archive:
    archive.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\n")
    archive.writestr("BOOT-INF/classes/example/Application.class", b"class")
    archive.writestr("BOOT-INF/lib/example.jar", b"library")

with zipfile.ZipFile(root / "plain.zip", "w") as archive:
    archive.writestr("README.txt", "not a Spring Boot application")

(root / "corrupt.jar").write_bytes(b"not a zip file")
PY

bash "${validator}" --validate-only "${test_root}/valid.jar"

if bash "${validator}" --validate-only "${test_root}/plain.zip" >/dev/null 2>&1; then
  echo "일반 ZIP 파일이 Spring Boot JAR 검증을 통과했습니다." >&2
  exit 1
fi

if bash "${validator}" --validate-only "${test_root}/corrupt.jar" >/dev/null 2>&1; then
  echo "손상된 파일이 Spring Boot JAR 검증을 통과했습니다." >&2
  exit 1
fi

echo "배포 JAR 검증 테스트가 통과했습니다."
