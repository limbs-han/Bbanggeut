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

# mediapipe가 끌고 오는 opencv-contrib-python은 GUI용 빌드라 libxcb·libGL 같은
# X11 공유 라이브러리를 링크한다. Agent 이미지에는 그것이 없어 `import cv2`가
# `ImportError: libxcb.so.1`로 죽고, test_cut_selector 수집 단계에서 빌드가
# 멈춘다. 헤드리스 빌드로 갈아끼우면 그 라이브러리를 아예 요구하지 않는다.
#
# Agent 이미지에 libxcb1 등을 넣는 방법도 있지만, 그러면 opencv가 새 라이브러리를
# 요구할 때마다 이미지를 다시 빌드해야 한다. CI는 화면을 쓰지 않으므로 헤드리스가
# 맞다. 컨테이너 이미지(Dockerfile.local)는 운영에서 그대로 쓰므로 건드리지 않는다.
"${venv}/bin/python" -m pip uninstall --quiet --yes \
  opencv-contrib-python opencv-python >/dev/null 2>&1 || true
"${venv}/bin/python" -m pip install --quiet opencv-python-headless

"${venv}/bin/python" -m pytest video_editor -q
