from pathlib import Path
import unittest


class EdgeAiRecordingStartupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = (
            Path(__file__).resolve().parent / "run_edge_ai_recording.sh"
        ).read_text(encoding="utf-8")

    def test_yamnet_gets_bounded_head_start_before_other_workers(self) -> None:
        yamnet_launch = self.script.index("start_yamnet")
        readiness_wait = self.script.index("while ! yamnet_has_inference")
        uploader_launch = self.script.index('"${UPLOADER_COMMAND[@]}"')
        yolo_launch = self.script.index('"${YOLO_COMMAND[@]}"')

        self.assertLess(yamnet_launch, readiness_wait)
        self.assertLess(readiness_wait, uploader_launch)
        self.assertLess(uploader_launch, yolo_launch)

    def test_readiness_uses_wall_clock_deadline(self) -> None:
        self.assertIn('yamnet_wait_started="$(date +%s)"', self.script)
        self.assertIn('now="$(date +%s)"', self.script)
        self.assertNotIn(
            "yamnet_ready_deadline=$((SECONDS +",
            self.script,
        )

    def test_readiness_timeout_continues_in_degraded_mode(self) -> None:
        timeout_start = self.script.index(
            "if (( now >= yamnet_ready_deadline )); then"
        )
        timeout_end = self.script.index("\n    fi", timeout_start)
        timeout_block = self.script[timeout_start:timeout_end]

        self.assertIn("Continuing in degraded mode", timeout_block)
        self.assertIn('"UNAVAILABLE"', timeout_block)
        self.assertIn("break", timeout_block)
        self.assertNotIn("exit 1", timeout_block)

    def test_yamnet_exit_restarts_only_yamnet(self) -> None:
        supervisor_start = self.script.rindex("while true; do")
        supervisor = self.script[supervisor_start:]

        self.assertIn("YAMNET_RESTART_DELAY_SECONDS", self.script)
        self.assertIn("restarting only YAMNet", supervisor)
        self.assertIn('write_yamnet_status "RESTARTING"', supervisor)
        self.assertIn("start_yamnet", supervisor)
        self.assertIn(
            'if [[ "$pid" == "$YAMNET_PID" || "$pid" == "$AUDIO_SHADOW_PID" ]]',
            supervisor,
        )

    def test_audio_shadow_is_disabled_and_non_authoritative_by_default(self) -> None:
        self.assertIn(': "${AUDIO_SHADOW_ENABLED:=false}"', self.script)
        self.assertIn("authority=none", self.script)
        self.assertIn("audio_shadow_runner.py", self.script)
        self.assertNotIn("--event-dir \"$AUDIO_SHADOW", self.script)

    def test_audio_shadow_failure_does_not_stop_production_workers(self) -> None:
        supervisor_start = self.script.rindex("while true; do")
        supervisor = self.script[supervisor_start:]

        self.assertIn("production YAMNet remains authoritative", supervisor)
        self.assertIn("Restarting EfficientAT shadow recorder", supervisor)
        self.assertIn("start_audio_shadow", supervisor)

    def test_yamnet_status_records_do_not_satisfy_readiness(self) -> None:
        self.assertIn(
            """grep -q '"selectedScore"' "$YAMNET_DIAGNOSTICS_PATH" 2>/dev/null""",
            self.script,
        )
        self.assertIn(
            'write_yamnet_status "STARTING" "Waiting for first inference"',
            self.script,
        )

    def test_cleanup_escalates_and_has_no_unbounded_wait(self) -> None:
        cleanup_start = self.script.index("cleanup() {")
        cleanup_end = self.script.index("\n}\ntrap cleanup", cleanup_start)
        cleanup = self.script[cleanup_start:cleanup_end]

        self.assertIn("wait_for_children_to_stop 20", cleanup)
        self.assertIn("wait_for_children_to_stop 8", cleanup)
        self.assertIn('kill -INT "$pid"', cleanup)
        self.assertIn('kill -TERM "$pid"', cleanup)
        self.assertIn('kill -KILL "$pid"', cleanup)
        self.assertNotIn("wait 2>/dev/null", cleanup)

    def test_yolo_runtime_is_selected_before_workers_start(self) -> None:
        selection = self.script.index('YOLO_SELECTOR_COMMAND=(')
        yamnet_launch = self.script.index("start_yamnet")
        yolo_model_argument = self.script.index(
            '--model "$YOLO_SELECTED_MODEL"'
        )

        self.assertLess(selection, yamnet_launch)
        self.assertLess(selection, yolo_model_argument)

    def test_yolo_auto_runtime_has_explicit_pytorch_fallback(self) -> None:
        self.assertIn(': "${YOLO_RUNTIME:=auto}"', self.script)
        self.assertIn(
            ': "${YOLO_PYTORCH_MODEL_PATH:=${SCRIPT_DIR}/yolov8n.pt}"',
            self.script,
        )
        self.assertIn(
            '"${SCRIPT_DIR}/yolo_runtime_selector.py"',
            self.script,
        )
        self.assertIn(
            '--result-file "$YOLO_SELECTION_FILE"',
            self.script,
        )
        self.assertIn("forcing PyTorch fallback", self.script)


if __name__ == "__main__":
    unittest.main()
