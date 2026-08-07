from pathlib import Path
import unittest


class EdgeAiRecordingStartupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = (
            Path(__file__).resolve().parent / "run_edge_ai_recording.sh"
        ).read_text(encoding="utf-8")

    def test_detector_gets_bounded_head_start_before_other_workers(self) -> None:
        detector_launch = self.script.index("start_audio_shadow")
        readiness_wait = self.script.index("! detector_has_inference")
        uploader_launch = self.script.index('"${UPLOADER_COMMAND[@]}"')
        yolo_launch = self.script.index('"${YOLO_COMMAND[@]}"')

        self.assertLess(detector_launch, readiness_wait)
        self.assertLess(readiness_wait, uploader_launch)
        self.assertLess(uploader_launch, yolo_launch)

    def test_readiness_uses_wall_clock_deadline(self) -> None:
        self.assertIn('yamnet_wait_started="$(date +%s)"', self.script)
        self.assertIn('now="$(date +%s)"', self.script)
        self.assertNotIn(
            "yamnet_ready_deadline=$((SECONDS +",
            self.script,
        )

    def test_efficientat_holds_event_authority_by_default(self) -> None:
        self.assertIn(': "${AUDIO_EVENT_MODEL:=efficientat}"', self.script)

        model_case = self.script.index('case "$AUDIO_EVENT_MODEL" in')
        efficientat_branch = self.script.index("efficientat)", model_case)
        yamnet_branch = self.script.index("    yamnet)", model_case)
        branch = self.script[efficientat_branch:yamnet_branch]

        self.assertIn("YAMNET_START=false", branch)
        self.assertIn("AUDIO_SHADOW_START=true", branch)
        self.assertIn("AUDIO_SHADOW_OPERATIONAL=true", branch)

    def test_sensitivity_maps_to_the_three_measured_thresholds(self) -> None:
        self.assertIn(': "${AUDIO_SENSITIVITY:=default}"', self.script)

        sensitivity_case = self.script.index('case "$AUDIO_SENSITIVITY" in')
        block = self.script[sensitivity_case:]
        block = block[: block.index("esac")]

        for step, threshold in (
            ("sensitive", "0.0169"),
            ("default", "0.03"),
            ("insensitive", "0.08"),
        ):
            branch = block.index(f"{step})")
            self.assertIn(
                f"AUDIO_SENSITIVITY_LAUGHTER_THRESHOLD={threshold}",
                block[branch : branch + 120],
            )

    def test_sensitivity_only_supplies_a_default_threshold(self) -> None:
        # An explicit threshold has to win, otherwise a field experiment
        # cannot pin a value without inventing a new sensitivity step.
        self.assertIn(
            ': "${AUDIO_SHADOW_LAUGHTER_THRESHOLD:='
            '$AUDIO_SENSITIVITY_LAUGHTER_THRESHOLD}"',
            self.script,
        )

    def test_unknown_sensitivity_stops_the_stack(self) -> None:
        sensitivity_case = self.script.index('case "$AUDIO_SENSITIVITY" in')
        block = self.script[sensitivity_case:]
        block = block[: block.index("esac")]

        self.assertIn("AUDIO_SENSITIVITY must be one of", block)
        self.assertIn("exit 2", block)

    def test_clap_requires_two_consecutive_windows(self) -> None:
        # One window separates applause from a door slam only by loudness.
        # Laughter can use 1; clapping cannot.
        self.assertIn(': "${AUDIO_SHADOW_CLAP_CONSECUTIVE:=2}"', self.script)
        self.assertIn(': "${AUDIO_SHADOW_LAUGHTER_CONSECUTIVE:=1}"', self.script)

    def test_only_the_authoritative_detector_writes_triggers(self) -> None:
        # YAMNet is always launched with --event-dir, so it must not start
        # while EfficientAT is operational or both would create events.
        self.assertIn(
            'if [[ "$YAMNET_START" == true ]]; then\n    start_yamnet',
            self.script,
        )
        operational_arguments = self.script.index(
            'if [[ "$AUDIO_SHADOW_OPERATIONAL" == true ]]; then'
        )
        block = self.script[operational_arguments:]
        self.assertIn("--operational", block)
        self.assertIn('--event-dir "$EVENT_DIR"', block)

    def test_audio_events_can_be_disabled_entirely(self) -> None:
        model_case = self.script.index('case "$AUDIO_EVENT_MODEL" in')
        none_branch = self.script.index("    none)", model_case)
        branch = self.script[none_branch:self.script.index("    *)", none_branch)]

        self.assertIn("YAMNET_START=false", branch)
        self.assertIn("AUDIO_SHADOW_START=false", branch)
        self.assertIn("AUDIO_SHADOW_OPERATIONAL=false", branch)

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

    def test_detector_exit_restarts_only_that_detector(self) -> None:
        supervisor_start = self.script.rindex("while true; do")
        supervisor = self.script[supervisor_start:]

        self.assertIn("YAMNET_RESTART_DELAY_SECONDS", self.script)
        self.assertIn("restarting only YAMNet", supervisor)
        self.assertIn("restarting only EfficientAT", supervisor)
        self.assertIn('write_detector_status "RESTARTING"', supervisor)
        self.assertIn("start_yamnet", supervisor)
        self.assertIn("start_audio_shadow", supervisor)
        self.assertIn(
            'if [[ "$pid" == "$YAMNET_PID" || "$pid" == "$AUDIO_SHADOW_PID" ]]',
            supervisor,
        )

    def test_shadow_companion_stays_non_authoritative(self) -> None:
        # AUDIO_SHADOW_ENABLED only adds a shadow beside YAMNet; it must never
        # be what grants event authority.
        self.assertIn(': "${AUDIO_SHADOW_ENABLED:=false}"', self.script)
        self.assertIn("audio_shadow_runner.py", self.script)

        model_case = self.script.index('case "$AUDIO_EVENT_MODEL" in')
        yamnet_branch = self.script.index("    yamnet)", model_case)
        branch = self.script[yamnet_branch:self.script.index("    none)", model_case)]

        self.assertIn("AUDIO_SHADOW_OPERATIONAL=false", branch)
        self.assertIn("AUDIO_SHADOW_ENABLED", branch)

    def test_audio_shadow_failure_does_not_stop_production_workers(self) -> None:
        supervisor_start = self.script.rindex("while true; do")
        supervisor = self.script[supervisor_start:]

        self.assertIn("production YAMNet remains authoritative", supervisor)
        self.assertIn("Restarting EfficientAT shadow recorder", supervisor)
        self.assertIn("start_audio_shadow", supervisor)

    def test_status_records_do_not_satisfy_readiness(self) -> None:
        self.assertIn(
            """grep -q '"selectedScore"' \\\n        "$AUDIO_DETECTOR_DIAGNOSTICS_PATH" 2>/dev/null""",
            self.script,
        )
        self.assertIn(
            'write_detector_status "STARTING" "Waiting for first inference"',
            self.script,
        )

    def test_readiness_and_dashboard_follow_the_authoritative_detector(
        self,
    ) -> None:
        self.assertIn(
            'AUDIO_DETECTOR_DIAGNOSTICS_PATH="$AUDIO_SHADOW_DIAGNOSTICS_PATH"',
            self.script,
        )
        self.assertIn(
            'AUDIO_DETECTOR_DIAGNOSTICS_PATH="$YAMNET_DIAGNOSTICS_PATH"',
            self.script,
        )
        self.assertIn(
            '--dashboard-yamnet-diagnostics "$AUDIO_DETECTOR_DIAGNOSTICS_PATH"',
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
