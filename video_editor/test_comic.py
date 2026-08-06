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
from video_editor.comic_jobs import ComicJob, ComicJobManager


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


def _window(
    start_ms: int,
    event: float,
    *,
    face: float = 1.0,
    quality: float = 1.0,
    bin_ms: int = 1_000,
) -> dict:
    return {
        "startMs": start_ms,
        "endMs": start_ms + bin_ms,
        "eventScore": event,
        "features": {
            "facePresence": face,
            "faceProminence": face,
            "visualQuality": quality,
        },
    }


class PanelTimestampTest(unittest.TestCase):
    """만화 칸으로 쓸 프레임을 점수 타임라인에서 고른다.

    등분으로 뽑던 동안에는 웃음이 3초에 터져도 6·18·30초를 가져갔다. 편집(자동
    컷·줌)이 이미 같은 분석을 쓰고 있는데 만화만 쓰지 않았다.
    """

    def test_picks_the_high_scoring_moments(self) -> None:
        timeline = [_window(index * 1_000, 0.1) for index in range(20)]
        timeline[4]["eventScore"] = 0.9
        timeline[14]["eventScore"] = 0.8

        picked = comic.panel_timestamps(timeline, duration=20.0, count=2)

        self.assertEqual([4.5, 14.5], picked)

    def test_returns_moments_in_time_order(self) -> None:
        """점수 순으로 돌려주면 기승전결이 뒤집힌 만화가 나온다."""
        timeline = [_window(index * 1_000, 0.1) for index in range(20)]
        timeline[15]["eventScore"] = 0.9
        timeline[3]["eventScore"] = 0.7

        picked = comic.panel_timestamps(timeline, duration=20.0, count=2)

        self.assertEqual(sorted(picked), picked)

    def test_spreads_picks_so_four_panels_are_not_the_same_second(self) -> None:
        """웃음 한 번이 여러 구간에 걸친다. 간격이 없으면 네 칸이 같은 그림이다."""
        timeline = [_window(index * 1_000, 0.1) for index in range(40)]
        for index in (10, 11, 12, 13):
            timeline[index]["eventScore"] = 0.9

        picked = comic.panel_timestamps(timeline, duration=40.0, count=4)

        gaps = [later - earlier for earlier, later in zip(picked, picked[1:])]
        self.assertTrue(all(gap >= 5.0 for gap in gaps), picked)

    def test_prefers_a_visible_face_over_a_loud_empty_room(self) -> None:
        """eventScore는 소리 중심이다. 화면 밖 웃음은 만화 칸으로 빈 방 사진이다."""
        timeline = [_window(index * 1_000, 0.1) for index in range(20)]
        timeline[4] = _window(4_000, 0.62, face=0.0, quality=0.0)
        timeline[14] = _window(14_000, 0.55, face=1.0, quality=1.0)

        picked = comic.panel_timestamps(timeline, duration=20.0, count=1)

        self.assertEqual([14.5], picked)

    def test_falls_back_to_even_spacing_without_a_timeline(self) -> None:
        """분석을 아직 안 돌린 영상도 만화는 만들 수 있어야 한다."""
        self.assertEqual(
            comic.frame_timestamps(20.0, 4),
            comic.panel_timestamps([], duration=20.0, count=4),
        )

    def test_short_clip_still_fills_every_panel(self) -> None:
        """간격을 지키다 개수를 못 채우면 프레임이 모자라 인물표가 흔들린다."""
        timeline = [_window(index * 1_000, 0.5) for index in range(4)]

        picked = comic.panel_timestamps(timeline, duration=4.0, count=4)

        self.assertEqual(4, len(picked))
        self.assertEqual(sorted(set(picked)), picked)

    def test_skips_the_black_edges_of_the_clip(self) -> None:
        """클립 앞뒤는 검은 화면이거나 흔들린다 — 등분이 피하던 것과 같은 이유."""
        timeline = [_window(index * 1_000, 0.1) for index in range(20)]
        timeline[0]["eventScore"] = 1.0
        timeline[19]["eventScore"] = 1.0

        picked = comic.panel_timestamps(timeline, duration=20.0, count=1)

        self.assertNotIn(0.5, picked)
        self.assertNotIn(19.5, picked)


class DiscardTest(unittest.TestCase):
    """만화 삭제가 그리는 중인 작업과 부딪히는 자리."""

    def _manager(self) -> ComicJobManager:
        return ComicJobManager(render=lambda *_: None)

    def test_discard_removes_a_finished_job(self) -> None:
        manager = self._manager()
        manager._jobs["v1"] = ComicJob(video_id="v1", status="done")

        self.assertTrue(manager.discard("v1"))
        self.assertIsNone(manager.get("v1"))

    def test_discard_refuses_while_the_worker_is_drawing(self) -> None:
        """기록만 지우면 작업자가 다 그린 뒤 panel.png를 다시 써서 되살아난다."""
        manager = self._manager()
        manager._jobs["v1"] = ComicJob(video_id="v1", status="running")

        self.assertFalse(manager.discard("v1"))
        self.assertIsNotNone(manager.get("v1"))

    def test_discarding_a_job_that_never_existed_succeeds(self) -> None:
        """만든 적 없는 만화를 지우라고 해도 사용자가 원한 상태는 이미 이뤄졌다."""
        self.assertTrue(self._manager().discard("v-none"))


if __name__ == "__main__":
    unittest.main()


class OuterMarginTrimTest(unittest.TestCase):
    """모델이 2x2 바깥에 그린 흰 테두리를 잘라내는 판단 로직.

    앱은 칸을 그림의 수학적 4등분으로 잡고 그 가운데에 자막 띠를 앉힌다.
    테두리가 있으면 왼쪽 칸의 실제 중심이 오른쪽으로 밀리는데 띠는 25%에
    그대로 앉아, 좌우 띠가 서로 반대 방향으로 빗겨난다. 실측(1024x1024)에서
    사면 40~42px이었고 그때 어긋남이 16px이었다.

    ffmpeg 없이 검증할 수 있는 부분만 본다 — 검출값 파싱과 믿을지 말지의 판단.
    """

    def test_parses_last_crop_line(self) -> None:
        # cropdetect는 프레임마다 한 줄씩 남긴다. 마지막 값이 가장 정확하다.
        stderr = (
            "[Parsed_cropdetect_1 @ 0x1] x1:20 x2:1000 crop=944:940:40:42\n"
            "[Parsed_cropdetect_1 @ 0x1] x1:20 x2:1000 crop=944:942:40:41\n"
        )
        self.assertEqual((944, 942, 40, 41), comic.parse_crop_box(stderr))

    def test_no_crop_line_is_none(self) -> None:
        self.assertIsNone(comic.parse_crop_box("ffmpeg version 7.0\n"))

    def test_measured_real_margin_is_trusted(self) -> None:
        # 실서버 만화의 실측값이다. 이것을 믿지 못하면 고치는 의미가 없다.
        self.assertTrue(comic.crop_box_is_trustworthy((944, 942, 40, 41), 1024, 1024))

    def test_trimming_too_much_is_not_trusted(self) -> None:
        # 밝은 화풍이면 칸 내용까지 테두리로 오인될 수 있다. 그때 잘라 버리면
        # 그림이 망가진다 — 띠가 조금 빗겨나는 것보다 나쁘다.
        self.assertFalse(comic.crop_box_is_trustworthy((500, 500, 262, 262), 1024, 1024))

    def test_box_outside_the_image_is_not_trusted(self) -> None:
        self.assertFalse(comic.crop_box_is_trustworthy((1000, 1000, 40, 40), 1024, 1024))
        self.assertFalse(comic.crop_box_is_trustworthy((0, 940, 40, 42), 1024, 1024))
        self.assertFalse(comic.crop_box_is_trustworthy((944, 940, -1, 42), 1024, 1024))

    def test_reads_png_size_without_an_image_library(self) -> None:
        # Pillow·numpy는 분석 전용 의존성이라 이 경로에 없을 수 있다.
        header = (
            b"\x89PNG\r\n\x1a\n"
            + b"\x00\x00\x00\rIHDR"
            + (1024).to_bytes(4, "big")
            + (768).to_bytes(4, "big")
            + b"\x08\x06\x00\x00\x00"
        )
        self.assertEqual((1024, 768), comic.png_size(header))

    def test_non_png_has_no_size(self) -> None:
        self.assertIsNone(comic.png_size(b"not a png"))
        self.assertIsNone(comic.png_size(b""))

    def test_prompt_forbids_the_outer_frame(self) -> None:
        # 서버가 잘라내기는 하지만, 애초에 안 그리게 하는 것이 낫다.
        prompt = comic.build_image_prompt(CUTS)
        self.assertIn("no outer border", prompt)
        self.assertIn("edge to edge", prompt)
