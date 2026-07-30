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
