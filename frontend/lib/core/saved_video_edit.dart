class SavedVideoEdit {
  const SavedVideoEdit({
    required this.videoPath,
    this.coverPath,
    this.metaPath,
  });

  final String videoPath;
  final String? coverPath;
  final String? metaPath;
}
