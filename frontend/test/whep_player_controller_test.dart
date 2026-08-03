import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:william_james_app/core/whep_player_controller.dart';

void main() {
  test('WHEP offer requests both video and audio tracks', () {
    expect(WhepPlayerController.receiveMediaTypes, [
      RTCRtpMediaType.RTCRtpMediaTypeVideo,
      RTCRtpMediaType.RTCRtpMediaTypeAudio,
    ]);
  });

  test('WHEP answer must contain an active audio media section', () {
    expect(
      WhepPlayerController.hasActiveAudioMedia(
        'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n',
      ),
      isTrue,
    );
    expect(
      WhepPlayerController.hasActiveAudioMedia(
        'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\nm=audio 0 UDP/TLS/RTP/SAVPF 0\r\n',
      ),
      isFalse,
    );
    expect(
      WhepPlayerController.hasActiveAudioMedia(
        'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=inactive\r\n',
      ),
      isFalse,
    );
    expect(
      WhepPlayerController.hasActiveAudioMedia(
        'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=recvonly\r\n',
      ),
      isFalse,
    );
    expect(
      WhepPlayerController.hasActiveAudioMedia(
        'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=sendonly\r\n',
      ),
      isTrue,
    );
    expect(
      WhepPlayerController.hasActiveAudioMedia(
        'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n',
      ),
      isFalse,
    );
  });

  test('WHEP playback requires inbound audio RTP packets', () {
    expect(
      WhepPlayerController.hasInboundAudioPackets([
        StatsReport('video', 'inbound-rtp', 0, {
          'kind': 'video',
          'packetsReceived': 120,
          'bytesReceived': 2048,
        }),
        StatsReport('audio', 'inbound-rtp', 0, {
          'kind': 'audio',
          'packetsReceived': 0,
          'bytesReceived': 0,
        }),
      ]),
      isFalse,
    );
    expect(
      WhepPlayerController.hasInboundAudioPackets([
        StatsReport('audio', 'inbound-rtp', 0, {
          'mediaType': 'audio',
          'packetsReceived': '4',
          'bytesReceived': '512',
        }),
      ]),
      isTrue,
    );
  });

  test('인바운드 영상 통계에서 프레임 수와 평균 버퍼 지연을 읽는다', () {
    final sample = WhepPlayerController.readInboundVideo([
      StatsReport('audio', 'inbound-rtp', 0, {
        'kind': 'audio',
        'framesDecoded': 999,
      }),
      StatsReport('video', 'inbound-rtp', 0, {
        'kind': 'video',
        'framesDecoded': 240,
        // 누적 1.2초를 10프레임이 나눠 가졌다 = 한 장에 120ms.
        'jitterBufferDelay': 1.2,
        'jitterBufferEmittedCount': 10,
      }),
    ]);

    expect(sample, isNotNull);
    expect(sample!.framesDecoded, 240);
    expect(sample.bufferDelay, const Duration(milliseconds: 120));
  });

  test('버퍼 지연 통계를 주지 않는 기기에서는 지연을 모른다고 둔다', () {
    final sample = WhepPlayerController.readInboundVideo([
      StatsReport('video', 'inbound-rtp', 0, {
        'mediaType': 'video',
        'framesDecoded': '12',
      }),
    ]);

    expect(sample?.framesDecoded, 12);
    expect(sample?.bufferDelay, isNull);
  });

  test('프레임이 계속 오고 지연이 낮으면 실시간 맨 앞이다', () {
    expect(
      WhepPlayerController.judgeLiveEdge(
        bufferDelay: const Duration(milliseconds: 140),
        sinceLastNewFrame: const Duration(milliseconds: 200),
      ),
      LiveEdge.live,
    );
  });

  test('화면이 멈춰 있으면 연결이 살아 있어도 뒤처진 것이다', () {
    expect(
      WhepPlayerController.judgeLiveEdge(
        bufferDelay: const Duration(milliseconds: 90),
        sinceLastNewFrame: WhepPlayerController.maxFrameStall,
      ),
      LiveEdge.behind,
    );
  });

  test('버퍼 지연이 한계를 넘으면 뒤처진 것이다', () {
    expect(
      WhepPlayerController.judgeLiveEdge(
        bufferDelay:
            WhepPlayerController.maxLiveEdgeDelay +
            const Duration(milliseconds: 1),
        sinceLastNewFrame: Duration.zero,
      ),
      LiveEdge.behind,
    );
  });

  test('지연을 모르는 기기에서는 프레임만 오면 실시간으로 본다', () {
    expect(
      WhepPlayerController.judgeLiveEdge(
        bufferDelay: null,
        sinceLastNewFrame: const Duration(milliseconds: 500),
      ),
      LiveEdge.live,
    );
  });

  test('WHEP 세션 URL에 단기 인증 파라미터를 유지한다', () {
    final sessionUri = WhepPlayerController.copyAccessQuery(
      Uri.parse('https://media.example/webrtc/live/id/whep/session'),
      Uri.parse(
        'https://media.example/webrtc/live/id/whep'
        '?streamId=id&token=short-lived',
      ),
    );

    expect(sessionUri.queryParameters['streamId'], 'id');
    expect(sessionUri.queryParameters['token'], 'short-lived');
  });
}
