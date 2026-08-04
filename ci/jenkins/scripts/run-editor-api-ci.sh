#!/usr/bin/env bash
set -euo pipefail

# editor-api(video_editor)는 Backend 스테이지가 배포 아티팩트에 담아
# 실서버로 나가는 서비스인데, 테스트는 어느 스테이지도 돌리지 않았다.
# 서비스·만화·렌더·컷 선택 테스트를 여기서 돌린다. 분석 의존성
# (mediapipe·av)은 test_cut_selector가 cv2를 임포트해서 필요하다 —
# 모델 파일은 필요 없다(모델 없는 환경 폴백까지가 테스트 대상이다).

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${repo_root}"

venv=".venv-editor-ci"
python3 -m venv "${venv}"
"${venv}/bin/python" -m pip install --quiet --upgrade pip
"${venv}/bin/python" -m pip install --quiet \
  -r video_editor/requirements-service.txt \
  -r video_editor/requirements-analysis.txt \
  pytest

"${venv}/bin/python" -m pytest video_editor -q
