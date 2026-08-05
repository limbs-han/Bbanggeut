"""4컷 만화 워커 — 네트워크와 ffmpeg 없이 검증하는 부분.

여기서 고정하는 것은 **조립 규칙과 계약**이다. GMS 호출과 프레임 추출은 바깥
프로세스에 달려 있어 여기서 확인하지 않는다.

가장 중요한 두 가지:
- 그림 프롬프트에 **대사가 새어 들어가지 않는다** — 들어가면 모델이 그 글자를
  그림에 그려서, 앱이 얹는 자막과 겹친다.
- 컷이 4개가 아니면 **던진다** — 그림이 2x2 격자 한 장이라 얹을 칸이 안 맞는다.
"""

from __future__ import annotations

import base64
import unittest

from video_editor import comic


def _payload(text: str) -> dict:
    return {"candidates": [{"content": {"parts": [{"text": text}]}}]}


def _script_json(cut_count: int = 4) -> str:
    cuts = ", ".join(
        f'{{"beat": "컷{index}", "scene": "장면{index}", "dialogue": "대사{index}"}}'
        for index in range(cut_count)
    )
    return (
        '{"characters": [{"label": "아빠", "appearance": "30대 남성, 회색 후드티"}],'
        ' "setting": "밝은 낮의 거실", "cuts": [' + cuts + "]}"
    )


CUTS = [
    {"beat": "빌드업", "scene": "아빠가 컵에 손을 뻗는 순간", "dialogue": "그거 만지지 마"},
    {"beat": "전개", "scene": "아이가 손을 뒤로 감추는 순간", "dialogue": "안 만졌는데요"},
    {"beat": "절정", "scene": "컵이 바닥에 흩어져 있는 순간", "dialogue": None},
    {"beat": "여운", "scene": "온 가족이 마주 보며 웃는 순간", "dialogue": "안 만졌다면서"},
]
CHARACTERS = [
    {"label": "아빠", "appearance": "30대 남성, 짧은 검은 머리, 검은 뿔테 안경, 회색 후드티"},
    {"label": "아이", "appearance": "다섯 살쯤, 단발, 노란 티셔츠"},
]


class ScriptParsingTest(unittest.TestCase):
    def test_reads_cuts_characters_and_setting(self) -> None:
        script = comic.parse_script(_payload(_script_json()))

        self.assertEqual(4, len(script["cuts"]))
        self.assertEqual("장면0", script["cuts"][0]["scene"])
        self.assertEqual("아빠", script["characters"][0]["label"])
        self.assertEqual("밝은 낮의 거실", script["setting"])

    def test_rejects_wrong_cut_count(self) -> None:
        for count in (3, 5):
            with self.subTest(count=count):
                with self.assertRaises(comic.ComicContractError):
                    comic.parse_script(_payload(_script_json(count)))

    def test_blank_dialogue_becomes_none(self) -> None:
        raw = _script_json().replace('"대사2"', '"   "')
        script = comic.parse_script(_payload(raw))

        self.assertIsNone(script["cuts"][2]["dialogue"])

    def test_rejects_cut_without_scene(self) -> None:
        raw = _script_json().replace('"scene": "장면1"', '"scene": ""')
        with self.assertRaises(comic.ComicContractError):
            comic.parse_script(_payload(raw))

    def test_rejects_non_json_text(self) -> None:
        with self.assertRaises(comic.ComicContractError):
            comic.parse_script(_payload("여기 4컷 만화 구성입니다!"))

    def test_rejects_empty_candidates(self) -> None:
        with self.assertRaises(comic.ComicContractError):
            comic.parse_script({"candidates": []})

    def test_drops_characters_missing_appearance(self) -> None:
        raw = _script_json().replace('"30대 남성, 회색 후드티"', '"  "')
        script = comic.parse_script(_payload(raw))

        self.assertEqual([], script["characters"])


class LinesToTextTest(unittest.TestCase):
    def test_prefixes_seconds_and_drops_blank_text(self) -> None:
        text = comic.lines_to_text(
            [
                {"startMs": 1500, "text": " 그거 만지지 마 "},
                {"startMs": 2000, "text": "   "},
                {"startMs": 4100, "text": "안 만졌는데요"},
            ]
        )

        self.assertEqual("[1.5s] 그거 만지지 마\n[4.1s] 안 만졌는데요", text)

    def test_empty_lines_give_empty_text(self) -> None:
        self.assertEqual("", comic.lines_to_text([]))


class FrameTimestampsTest(unittest.TestCase):
    def test_takes_middle_of_each_slice(self) -> None:
        # 처음(0초)과 끝을 피한다 — 검은 화면에 1,089토큰을 쓰지 않기 위해서다.
        stamps = comic.frame_timestamps(100.0, 4)

        self.assertEqual([12.5, 37.5, 62.5, 87.5], stamps)

    def test_zero_duration_gives_nothing(self) -> None:
        self.assertEqual([], comic.frame_timestamps(0.0, 4))
        self.assertEqual([], comic.frame_timestamps(-1.0, 4))


class ImagePromptTest(unittest.TestCase):
    def test_never_contains_dialogue(self) -> None:
        prompt = comic.build_image_prompt(
            CUTS, characters=CHARACTERS, setting="밝은 낮의 거실"
        )

        for cut in CUTS:
            if cut["dialogue"]:
                self.assertNotIn(
                    cut["dialogue"],
                    prompt,
                    "대사가 프롬프트에 들어가면 모델이 그림에 글자를 쓴다",
                )

    def test_repeats_character_sheet_verbatim(self) -> None:
        prompt = comic.build_image_prompt(CUTS, characters=CHARACTERS)

        for person in CHARACTERS:
            self.assertIn(person["appearance"], prompt)
        self.assertIn("IDENTICALLY in every panel", prompt)

    def test_orders_blocks_style_then_sheet_then_panels_then_rules(self) -> None:
        prompt = comic.build_image_prompt(
            CUTS, characters=CHARACTERS, setting="밝은 낮의 거실"
        )

        # 앞쪽 지시가 더 강하게 먹히므로 순서가 규칙이다.
        self.assertLess(prompt.index("2x2 grid"), prompt.index("CHARACTERS"))
        self.assertLess(prompt.index("CHARACTERS"), prompt.index("SETTING"))
        self.assertLess(prompt.index("SETTING"), prompt.index("Panel 1"))
        self.assertLess(prompt.index("Panel 4"), prompt.index("STRICT RULES"))

    def test_maps_cuts_to_reading_order(self) -> None:
        prompt = comic.build_image_prompt(CUTS)

        for index, position in enumerate(comic.PANEL_POSITIONS):
            self.assertIn(f"Panel {index + 1} ({CUTS[index]['beat']}, {position})", prompt)

    def test_forbids_text_and_bubbles(self) -> None:
        prompt = comic.build_image_prompt(CUTS)

        self.assertIn("no writing of any kind", prompt)
        self.assertIn("No speech bubbles", prompt)

    def test_never_names_the_artifacts_it_fears(self) -> None:
        """부정 지시도 그 물건을 모델에게 떠올리게 한다.

        "아래 1/4을 단순하게 두라(앱이 자막을 얹는다)"라고 적었더니 모델이 네 칸
        아래에 자막 띠와 아이콘을 그렸다(2026-08-04 실측). 자막·워터마크·카메라
        UI라는 단어 자체가 프롬프트에 나타나면 안 된다.
        """
        prompt = comic.build_image_prompt(CUTS).lower()

        for word in ("subtitle", "caption", "watermark", "camera ui", "timestamp"):
            self.assertNotIn(word, prompt)

    def test_works_without_sheet(self) -> None:
        # 시트 캐시를 잃어도 실패시키지 않는다 — 품질만 떨어진다.
        prompt = comic.build_image_prompt(CUTS)

        self.assertNotIn("CHARACTERS", prompt)
        self.assertIn("Panel 1", prompt)

    def test_rejects_wrong_cut_count(self) -> None:
        with self.assertRaises(comic.ComicContractError):
            comic.build_image_prompt(CUTS[:3])


class ImageResponseTest(unittest.TestCase):
    def test_reads_inline_data(self) -> None:
        blob = base64.b64encode(b"fake-png").decode()
        payload = {
            "candidates": [
                {"content": {"parts": [{"inlineData": {"data": blob}}]}}
            ]
        }

        self.assertEqual(b"fake-png", comic._first_image(payload))

    def test_accepts_snake_case_key(self) -> None:
        blob = base64.b64encode(b"fake-png").decode()
        payload = {
            "candidates": [
                {"content": {"parts": [{"inline_data": {"data": blob}}]}}
            ]
        }

        self.assertEqual(b"fake-png", comic._first_image(payload))

    def test_text_only_response_raises(self) -> None:
        # gemini-3.5-flash처럼 이미지를 못 내는 모델을 부르면 글만 돌아온다.
        with self.assertRaises(comic.ComicContractError):
            comic._first_image(_payload("Here is HTML to draw a red circle..."))


class UsageSummaryTest(unittest.TestCase):
    def test_includes_thinking_tokens(self) -> None:
        summary = comic.usage_summary(
            {
                "usageMetadata": {
                    "promptTokenCount": 1103,
                    "candidatesTokenCount": 1,
                    "thoughtsTokenCount": 124,
                    "totalTokenCount": 1228,
                }
            }
        )

        self.assertEqual(
            {"prompt": 1103, "candidates": 1, "thoughts": 124, "total": 1228},
            summary,
        )

    def test_missing_usage_gives_zeros(self) -> None:
        self.assertEqual(
            {"prompt": 0, "candidates": 0, "thoughts": 0, "total": 0},
            comic.usage_summary({}),
        )


class FrameBudgetTest(unittest.TestCase):
    """GMS는 요청 **크기**에서 끊는다. 장당 크기가 영상에 따라 배로 달라지므로
    개수가 아니라 바이트로 잘라야 한다 — 실서버에서 5장 203KB로 400을 받았다."""

    def test_drops_frames_past_the_budget(self) -> None:
        # base64는 3바이트를 4자로 만든다. 30,000바이트 → 40,000자.
        frames = [b"x" * 30_000] * 5

        kept = comic.fit_frame_budget(frames, budget=72_000)

        self.assertEqual(1, len(kept))

    def test_keeps_every_frame_that_fits(self) -> None:
        frames = [b"x" * 10_000] * 5

        self.assertEqual(5, len(comic.fit_frame_budget(frames, budget=72_000)))

    def test_keeps_one_frame_even_when_it_alone_exceeds(self) -> None:
        """한 장도 못 남기면 인물표를 못 뽑아 칸마다 다른 사람이 그려진다."""
        kept = comic.fit_frame_budget([b"x" * 200_000], budget=72_000)

        self.assertEqual(1, len(kept))

    def test_default_frame_count_fits_the_budget_at_measured_size(self) -> None:
        """실측 장당 14KB(320폭 q8) 기준으로 기본 장수가 예산 안에 들어온다."""
        frames = [b"x" * 10_500] * comic.FRAME_COUNT

        self.assertEqual(
            comic.FRAME_COUNT, len(comic.fit_frame_budget(frames))
        )


if __name__ == "__main__":
    unittest.main()
