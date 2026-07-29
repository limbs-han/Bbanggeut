import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/whep_player_controller.dart';

void main() {
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
