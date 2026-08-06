"""목록용 미리보기 — 어느 지점을 집는가, 그리고 백필이 입력을 어떻게 읽는가."""

from __future__ import annotations

import io
import unittest

from video_editor.backfill_thumbnails import read_rows
from video_editor.thumbnails import thumbnail_offset_seconds


class ThumbnailOffsetTest(unittest.TestCase):
    """감지 클립은 이벤트 앞뒤로 60초씩 잘라 만든다 — 가운데가 곧 웃은 시점이다.

    운영 데이터(2026-08-06): LAUGHTER 269건 중 183건이 120초±3초.
    """

    def test_takes_the_middle_which_is_the_event_moment(self) -> None:
        self.assertAlmostEqual(thumbnail_offset_seconds(120_000), 60.0)

    def test_shorter_clips_still_take_their_own_middle(self) -> None:
        self.assertAlmostEqual(thumbnail_offset_seconds(40_000), 20.0)

    def test_a_two_second_clip_does_not_land_on_the_first_frame(self) -> None:
        # 첫 프레임은 검은 화면이거나 흔들려서 목록에 검은 칸이 깔린다.
        self.assertGreater(thumbnail_offset_seconds(2_458), 0)
        self.assertAlmostEqual(thumbnail_offset_seconds(2_458), 1.229)

    def test_unknown_length_falls_back_to_an_early_but_nonzero_point(self) -> None:
        for missing in (None, 0, -1):
            self.assertEqual(thumbnail_offset_seconds(missing), 1.0)


class BackfillInputTest(unittest.TestCase):
    """`psql -t -A -F'|'` 출력을 그대로 읽는다 — 중간에 파일을 만들지 않는다."""

    def test_reads_id_key_and_duration(self) -> None:
        rows = read_rows(
            io.StringIO(
                "v1|private/d/events/v1.mp4|120000\n"
                "v2|private/d/events/v2.mp4|40000\n"
            )
        )
        self.assertEqual(
            rows,
            [
                ("v1", "private/d/events/v1.mp4", 120000),
                ("v2", "private/d/events/v2.mp4", 40000),
            ],
        )

    def test_skips_blank_and_short_lines(self) -> None:
        # psql은 마지막에 빈 줄을 남기고, 사람이 손으로 자른 목록도 들어온다.
        rows = read_rows(io.StringIO("\n  \nv1|k|0\n망가진줄\n"))
        self.assertEqual(rows, [("v1", "k", 0)])

    def test_treats_an_empty_duration_as_unknown(self) -> None:
        self.assertEqual(read_rows(io.StringIO("v1|k|\n")), [("v1", "k", 0)])
