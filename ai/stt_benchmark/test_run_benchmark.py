"""자체 점검. `python test_run_benchmark.py`로 돌린다.

두 곳만 검사한다 — 둘 다 조용히 틀려서 CER을 오염시킨 전력이 있다.

  normalize()  : 태그를 안 지우면 SenseVoice가 무조건 지고,
                 타임스탬프를 안 지우면 정답에 숫자가 섞인다.
  read_truth() : UTF-8 정답을 UTF-16으로 잘못 읽어 CER 57%를 모델 탓으로
                 오판한 적이 있다.
"""

import tempfile
from pathlib import Path

from run_benchmark import normalize, read_truth

# --- normalize ---------------------------------------------------------------

# 타임스탬프 줄은 사라지고 본문만 남는다 — 숫자 "0000"이 섞이지 않는다.
assert normalize("00:00\n두려움에 떨고 있구나.\n00:12\n같이 하자.") == "두려움에떨고있구나같이하자"

# SenseVoice의 감정·이벤트 태그와 정답지의 [불명]은 CER에서 빠진다.
assert normalize("<|ko|><|HAPPY|><|Laughter|>같이 하자") == "같이하자"
assert normalize("음 [불명] 같이 하자") == "음같이하자"

# 공백과 문장부호만 다른 두 문장은 완전 일치로 본다.
assert normalize("같이 하자.") == normalize("같이하자")

# 남는 것이 없어야 하는 입력.
assert normalize("00:18\n...\n") == ""

# AI Hub 이중 표기 — 철자(앞쪽)를 택한다. 발음 쪽을 택하면 모델이 "12월"을
# 내놓을 때마다 틀린 것으로 잡힌다.
assert normalize("(12월)/(십 이 월) 삼일") == "12월삼일"
assert normalize("(NCS)/(엔씨에스) 준비") == "NCS준비"

# AI Hub 잡음·간투어 태그는 사라지고 본문만 남는다.
assert normalize("o/ n/ 아 그 제가") == "아그제가"
# 알아들을 수 없는 구간 표기도 빠진다.
assert normalize("시간이 안 돼가지고 (()) 못 받아요") == "시간이안돼가지고못받아요"

# 태그 문자가 본문의 일부일 때 잘라먹지 않는다 — 앞이 공백일 때만 태그다.
assert normalize("공부/") == "공부"

# 회의 음성(464)의 비식별화·비언어 표기는 토큰째 사라진다. 실제 이름·웃음을
# 모델이 맞출 수 없으므로 정답에 남겨두면 무조건 오류로 잡힌다.
assert normalize("네 @상호명1 들어오시면") == "네들어오시면"
assert normalize("그래서 @웃음 말이죠") == "그래서말이죠"
assert normalize("@이름1 님과 @정당2 이야기") == "님과이야기"

# 이중 표기는 fetch_dataset.py가 풀어서 저장한다(데이터셋마다 철자 쪽이 반대).
# 여기 남은 것은 안전망으로 앞쪽을 택해 슬래시가 CER을 부풀리지 않게만 한다.
assert normalize("(아홉 건의)/(9건의) 사례") == "아홉건의사례"

# 배경음 표기는 낱말째 사라져야 한다. 괄호·슬래시만 지우면 'bgm'이 정답에
# 남아 CER을 부풀린다 — meeting에서 정답의 8.7%를 차지했다.
assert normalize("윤곽을 드러냈습니다. /(bgm)") == "윤곽을드러냈습니다"
assert normalize("집값을 잡을 수 있을까요? /(noise)") == "집값을잡을수있을까요"

# --- read_truth --------------------------------------------------------------

# 한글 6자 = UTF-8로 18바이트. 짝수여야 버그가 재현된다 — 홀수면 UTF-16
# 디코딩이 예외로 걸러져서 이 테스트가 아무것도 검사하지 못한다.
SENTENCE = "같이하자오늘"

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)

    # UTF-8(BOM 없음). 인코딩을 순서대로 시도하는 구현에서는 UTF-16 디코딩이
    # 예외 없이 "성공"해 한자 쓰레기가 나온다. 그 회귀를 여기서 막는다.
    (root / "a_original.txt").write_text(SENTENCE, encoding="utf-8")
    raw = (root / "a_original.txt").read_bytes()
    assert len(raw) % 2 == 0, "테스트 전제가 깨졌다 — 짝수 바이트여야 한다"
    try:
        raw.decode("utf-16")
    except UnicodeDecodeError:
        raise AssertionError("테스트 전제가 깨졌다 — UTF-16 오독이 재현되지 않는다")
    assert read_truth(root / "a.wav").strip() == SENTENCE

    # UTF-16(BOM 있음) — 사람이 메모장으로 저장한 정답이 이 형식이었다.
    (root / "b_original.txt").write_bytes(b"\xff\xfe" + SENTENCE.encode("utf-16-le"))
    assert read_truth(root / "b.wav").strip() == SENTENCE

    # UTF-8 BOM.
    (root / "c_original.txt").write_text(SENTENCE, encoding="utf-8-sig")
    assert read_truth(root / "c.wav").strip() == SENTENCE

print("normalize() / read_truth() 점검 통과")
