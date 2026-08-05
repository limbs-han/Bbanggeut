/// 전사문(AI 자막)을 서버에 보관하는 통로.
///
/// 저장소는 편집 서버(editor-api)다 — 분석 결과·편집 초안과 같은 곳이다. 앱이
/// 이미 그 서버를 직접 부르고 있어서(초안 저장·불러오기) 백엔드에 프록시를 하나
/// 더 두지 않는다.
library;

import '../../editor/edit_recommendation_client.dart';
import 'caption_line.dart';
import 'transcript_store.dart';

class HttpTranscriptRemote implements TranscriptRemote {
  HttpTranscriptRemote({EditRecommendationClient? client})
    : _client = client ?? EditRecommendationClient();

  final EditRecommendationClient _client;

  @override
  Future<List<CaptionLine>?> load(String videoId) async {
    if (!EditRecommendationClient.networkAllowed) return null;
    final lines = await _client.loadTranscript(videoId);
    if (lines == null) return null;
    return [
      for (final line in lines)
        if ((line['text'] as String?)?.trim().isNotEmpty == true)
          CaptionLine(
            startMs: (line['startMs'] as num?)?.toInt() ?? 0,
            endMs: (line['endMs'] as num?)?.toInt() ?? 0,
            text: line['text'] as String,
          ),
    ];
  }

  @override
  Future<void> save(String videoId, List<CaptionLine> lines) async {
    if (!EditRecommendationClient.networkAllowed) return;
    await _client.saveTranscript(videoId, [
      for (final line in lines)
        {'startMs': line.startMs, 'endMs': line.endMs, 'text': line.text},
    ]);
  }
}
