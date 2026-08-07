#!/usr/bin/env bash
#
# Jetson Edge AI 릴리스를 만든다.
#
# 지금까지 이 절차는 손으로 실행돼 왔고 저장소에 남아 있지 않았다. 그 기계에
# 접근하지 못하면 아무도 배포할 수 없는 상태였다. 관측된 규칙을 그대로 옮긴다.
#
#   ~/ai -> ~/ai_releases/<UTC타임스탬프>_<브랜치>_<짧은커밋>
#
# 기존 방식과 한 가지만 다르다. cp -a 대신 git archive 를 쓴다. 복사는 추적되지
# 않는 __pycache__ 와 fifo 까지 끌고 오는데, 그러면 릴리스 이름에 박힌 커밋과
# 실제 내용이 일치한다고 보장할 수 없다. git archive 는 그 커밋의 트리만 낸다.
# 런타임에 필요한 yolov8n.pt 를 포함해 필요한 파일은 모두 추적되고 있음을
# 확인했다.
#
# 전제: 젯슨에 저장소 체크아웃이 있어야 한다(기본 ~/william-james). 없으면
# 이 스크립트는 아무것도 하지 않고 만드는 방법을 알려준다. 윈도우에서 tar 를
# 밀어 넣는 기존 방식은 어느 커밋이 올라갔는지 남지 않아 릴리스 이름의 커밋과
# 내용이 일치한다고 보장할 수 없다.
#
# 최초 도입: ~/ai 가 심볼릭 링크가 아니라 실제 디렉터리이면 --apply 가 거부한다.
# 손으로 밀어 넣은 코드를 링크로 덮어써서 지워 버리지 않기 위해서다. 안내대로
# 옆으로 치운 뒤 다시 실행하면 된다.
#
# 사용법:
#   bash release-edge-ai.sh                     # 미리보기만 (기본)
#   bash release-edge-ai.sh --ref <커밋/브랜치>  # 대상 지정
#   sudo bash release-edge-ai.sh --apply        # 링크 교체까지
#   sudo bash release-edge-ai.sh --apply --restart   # 서비스 재시작까지
#
# set -e 는 쓰지 않는다. 검증 실패를 직접 붙잡아 설명해야 하기 때문이다.
set -uo pipefail

REPO_DIR="${WJ_REPO_DIR:-}"
RELEASE_ROOT="${WJ_RELEASE_ROOT:-}"
LINK_PATH="${WJ_LINK_PATH:-}"
REF="HEAD"
APPLY=0
RESTART=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ref) REF="${2:-}"; shift 2 ;;
        --apply) APPLY=1; shift ;;
        --restart) RESTART=1; shift ;;
        --repo) REPO_DIR="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
    esac
done

TARGET_USER="${SUDO_USER:-$(id -un)}"
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    echo "홈 디렉터리 해석 실패: user=${TARGET_USER}" >&2
    exit 1
fi
REPO_DIR="${REPO_DIR:-${USER_HOME}/william-james}"
RELEASE_ROOT="${RELEASE_ROOT:-${USER_HOME}/ai_releases}"
LINK_PATH="${LINK_PATH:-${USER_HOME}/ai}"

if [ ! -d "${REPO_DIR}/.git" ]; then
    echo "저장소를 찾지 못했습니다: ${REPO_DIR}" >&2
    echo >&2
    echo "이 스크립트는 젯슨 안의 체크아웃에서 릴리스를 뽑습니다." >&2
    echo "한 번만 만들어 두면 됩니다:" >&2
    echo >&2
    echo "  git clone https://lab.ssafy.com/s15-webmobile3-sub1/S15P11E201.git \\" >&2
    echo "      ${REPO_DIR}" >&2
    echo >&2
    echo "다른 위치를 쓰려면 --repo 또는 WJ_REPO_DIR 로 지정하세요." >&2
    exit 1
fi

git_repo() { git -c safe.directory='*' -C "$REPO_DIR" "$@"; }

COMMIT="$(git_repo rev-parse "$REF" 2>/dev/null)"
if [ -z "$COMMIT" ]; then
    echo "해석할 수 없는 ref: ${REF}" >&2
    exit 1
fi
SHORT="$(git_repo rev-parse --short "$COMMIT")"
BRANCH="$(git_repo rev-parse --abbrev-ref "$REF" 2>/dev/null)"
[ "$BRANCH" = "HEAD" ] && BRANCH="$(git_repo rev-parse --abbrev-ref HEAD)"
# 릴리스 이름에 슬래시가 들어가면 디렉터리가 중첩된다.
SAFE_BRANCH="$(printf '%s' "$BRANCH" | tr '/' '-')"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RELEASE_NAME="${STAMP}_${SAFE_BRANCH}_${SHORT}"
RELEASE_DIR="${RELEASE_ROOT}/${RELEASE_NAME}"
CURRENT_TARGET="$(readlink -f "$LINK_PATH" 2>/dev/null)"

echo "================ 릴리스 계획 ================"
printf '  저장소      %s\n' "$REPO_DIR"
printf '  대상 ref    %s -> %s (%s)\n' "$REF" "$SHORT" "$BRANCH"
printf '  새 릴리스   %s\n' "$RELEASE_DIR"
printf '  현재 링크   %s -> %s\n' "$LINK_PATH" "${CURRENT_TARGET:-(없음)}"
printf '  링크 교체   %s\n' "$([ "$APPLY" -eq 1 ] && echo 예 || echo 아니오 - 미리보기)"
printf '  서비스 재시작 %s\n' "$([ "$RESTART" -eq 1 ] && echo 예 || echo 아니오)"
echo "============================================="
echo

DIRTY="$(git_repo status --porcelain -- ai | head -n 5)"
if [ -n "$DIRTY" ]; then
    echo "[주의] 저장소 ai/ 에 커밋되지 않은 변경이 있습니다."
    echo "       git archive 는 커밋된 내용만 담으므로 아래 변경은 배포되지 않습니다."
    printf '%s\n' "$DIRTY" | sed 's/^/       /'
    echo
fi

if [ -e "$RELEASE_DIR" ]; then
    echo "이미 존재하는 릴리스 디렉터리입니다: ${RELEASE_DIR}" >&2
    exit 1
fi

echo ">>> 스냅샷 생성"
mkdir -p "$RELEASE_DIR" || exit 1
if ! git_repo archive --format=tar "$COMMIT" ai | tar -x -C "$RELEASE_DIR" --strip-components=1; then
    echo "git archive 실패. 릴리스 디렉터리를 정리합니다." >&2
    rm -rf "$RELEASE_DIR"
    exit 1
fi
printf '%s\n' "$COMMIT" > "${RELEASE_DIR}/DEPLOYED_COMMIT"
# sudo 로 실행하면 루트 소유로 만들어진다. 서비스는 ssafy 로 돌기 때문에
# 소유권을 넘겨두지 않으면 나중에 쓰기가 필요한 순간에 막힌다.
chown -R "${TARGET_USER}:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" \
    "$RELEASE_DIR" 2>/dev/null
printf '  파일 %s개\n' "$(find "$RELEASE_DIR" -type f | wc -l)"

echo
echo ">>> 릴리스 검증 (validate_jetson_release.sh)"
VALIDATOR="${RELEASE_DIR}/yolo/validate_jetson_release.sh"
if [ ! -r "$VALIDATOR" ]; then
    echo "검증 스크립트가 없습니다: ${VALIDATOR}" >&2
    rm -rf "$RELEASE_DIR"
    exit 1
fi
# 검증기는 ${HOME}/venvs/... 를 확인한다. root 로 실행하면 HOME 이 /root 가 되어
# 실제 venv 를 못 찾고 실패한다. 반드시 대상 사용자 권한으로 돌린다.
if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    printf '  %s 권한으로 실행합니다 (HOME=%s)\n' "$TARGET_USER" "$USER_HOME"
    VALIDATE_CMD=(sudo -u "$TARGET_USER" env "HOME=${USER_HOME}" bash "$VALIDATOR")
else
    VALIDATE_CMD=(bash "$VALIDATOR")
fi
if "${VALIDATE_CMD[@]}"; then
    echo "  검증 통과"
else
    echo
    echo "!!! 검증 실패. 링크를 교체하지 않고 중단합니다." >&2
    echo "    만들어진 릴리스: ${RELEASE_DIR}" >&2
    echo "    원인을 고친 뒤 다시 실행하세요." >&2
    exit 1
fi

if [ "$APPLY" -ne 1 ]; then
    echo
    echo "스냅샷 생성과 검증까지 끝났고, 링크는 그대로 둡니다."
    echo "  검증 통과한 릴리스: ${RELEASE_DIR}"
    echo "  아직 서비스가 쓰는 것은 여전히: ${CURRENT_TARGET:-(없음)}"
    echo
    echo "이 릴리스로 전환하려면:"
    echo "  sudo ln -sfn ${RELEASE_DIR} ${LINK_PATH}"
    echo "  sudo systemctl restart wj-edge-ai-recording.service"
    echo "또는 처음부터 다시:"
    echo "  sudo bash $0 --ref ${REF} --apply --restart"
    exit 0
fi

if [ -e "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
    echo >&2
    echo "!!! ${LINK_PATH} 가 심볼릭 링크가 아니라 실제 디렉터리입니다." >&2
    echo "    손으로 밀어 넣은 코드로 보입니다. 링크로 덮어쓰면 그대로" >&2
    echo "    사라지므로 중단합니다. 옆으로 치운 뒤 다시 실행하세요:" >&2
    echo >&2
    echo "      sudo systemctl stop wj-edge-ai-recording.service" >&2
    echo "      sudo mv ${LINK_PATH} ${LINK_PATH}.manual-\$(date -u +%Y%m%dT%H%M%SZ)" >&2
    echo "      sudo bash $0 --ref ${REF} --apply --restart" >&2
    echo >&2
    echo "    검증 통과한 릴리스는 남겨 둡니다: ${RELEASE_DIR}" >&2
    exit 1
fi

echo
echo ">>> 링크 교체"
# -n 이 없으면 링크가 기존 대상 디렉터리 안쪽에 만들어진다.
ln -sfn "$RELEASE_DIR" "$LINK_PATH" || exit 1
chown -h "${TARGET_USER}:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" \
    "$LINK_PATH" 2>/dev/null
printf '  %s -> %s\n' "$LINK_PATH" "$(readlink -f "$LINK_PATH")"

if [ "$RESTART" -eq 1 ]; then
    echo
    echo ">>> 서비스 재시작"
    systemctl restart wj-edge-ai-recording.service
    sleep 5
    printf '  wj-edge-ai-recording %s\n' \
        "$(systemctl is-active wj-edge-ai-recording.service 2>&1)"
else
    echo
    echo "서비스는 재시작하지 않았습니다. 반영하려면:"
    echo "  sudo systemctl restart wj-edge-ai-recording.service"
fi

echo
echo "================ 롤백 ================"
if [ -n "$CURRENT_TARGET" ]; then
    echo "  코드 전체를 이전 릴리스로 되돌리려면:"
    echo "    sudo ln -sfn ${CURRENT_TARGET} ${LINK_PATH}"
    echo "    sudo systemctl restart wj-edge-ai-recording.service"
else
    echo "  이전 링크 대상이 없어 롤백 경로를 안내할 수 없습니다."
fi
echo "  오디오 모델만 되돌리려면 기기 env 에서:"
echo "    AUDIO_EVENT_MODEL=yamnet"
echo "======================================"
