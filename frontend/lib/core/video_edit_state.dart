import 'dart:math' as math;

enum VideoEditRatio { original, shortForm }

class VideoEditState {
  VideoEditState({
    required this.durationMs,
    required this.originalAspectRatio,
    this.startMs = 0,
    int? endMs,
    this.selectedRatio = VideoEditRatio.original,
    this.selectedTool = 'cut',
  }) : endMs = endMs ?? durationMs;

  final int durationMs;
  final double originalAspectRatio;
  int startMs;
  int endMs;
  VideoEditRatio selectedRatio;
  String selectedTool;
  bool isSaving = false;
  bool hasUnsavedChanges = false;

  bool get isShortForm => selectedRatio == VideoEditRatio.shortForm;

  double get previewAspectRatio => isShortForm ? 9 / 16 : originalAspectRatio;

  int get clipDurationMs => math.max(0, endMs - startMs);

  bool get canSave => !isSaving && durationMs > 0;

  void selectRatio(VideoEditRatio ratio) {
    selectedRatio = ratio;
    hasUnsavedChanges = true;
  }

  void selectTool(String tool) {
    selectedTool = tool;
    hasUnsavedChanges = true;
  }

  void updateTrimRange({required int startMs, required int endMs}) {
    const minSegmentMs = 100;
    final safeStart = startMs.clamp(0, durationMs);
    final safeEnd = endMs.clamp(0, durationMs);
    final normalizedStart = safeStart <= safeEnd ? safeStart : safeEnd;
    final normalizedEnd = safeStart <= safeEnd ? safeEnd : safeStart;

    if (durationMs <= minSegmentMs) {
      this.startMs = 0;
      this.endMs = durationMs;
      hasUnsavedChanges = true;
      return;
    }

    if (normalizedEnd - normalizedStart < minSegmentMs) {
      if (normalizedStart + minSegmentMs <= durationMs) {
        this.startMs = normalizedStart;
        this.endMs = normalizedStart + minSegmentMs;
      } else {
        this.startMs = durationMs - minSegmentMs;
        this.endMs = durationMs;
      }
    } else {
      this.startMs = normalizedStart;
      this.endMs = normalizedEnd;
    }
    hasUnsavedChanges = true;
  }

  void setPlaybackPosition(int positionMs) {
    if (positionMs < startMs) {
      startMs = positionMs;
    }
    if (positionMs > endMs) {
      endMs = positionMs;
    }
    hasUnsavedChanges = true;
  }

  void markSaved() {
    hasUnsavedChanges = false;
    isSaving = false;
  }

  void markSaving() {
    isSaving = true;
  }

  void markSaveFailed() {
    isSaving = false;
  }
}
