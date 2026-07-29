import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';

void main() {
  test('로그인 인증 정보 불일치를 사용자용 문구로 구분한다', () async {
    final controller = AppController(
      api: _AccountApiClient(invalidLogin: true),
    );

    expect(await controller.login('member@example.com', 'wrong'), isFalse);
    expect(
      controller.errorMessage,
      '아이디 또는 비밀번호가 올바르지 않습니다. 입력한 정보를 다시 확인해 주세요.',
    );
    expect(controller.busy, isFalse);
    controller.dispose();
  });

  test('비밀번호 찾기 요청을 실제 API 계층으로 전달한다', () async {
    final api = _AccountApiClient();
    final controller = AppController(api: api);

    expect(
      await controller.requestPasswordReset(' member@example.com '),
      isTrue,
    );
    expect(api.resetEmail, 'member@example.com');
    controller.dispose();
  });

  test('현재 비밀번호와 새 비밀번호를 변경 API로 전달한다', () async {
    final api = _AccountApiClient();
    final controller = AppController(api: api);

    expect(
      await controller.changePassword('old-password', 'new-password'),
      isTrue,
    );
    expect(api.currentPassword, 'old-password');
    expect(api.newPassword, 'new-password');
    controller.dispose();
  });
}

class _AccountApiClient extends ApiClient {
  _AccountApiClient({this.invalidLogin = false});

  final bool invalidLogin;
  String? resetEmail;
  String? currentPassword;
  String? newPassword;

  @override
  Future<AuthSession> login(
    String email,
    String password, {
    bool persistSession = true,
  }) async {
    if (invalidLogin) {
      throw const ApiFailure(
        '이메일 또는 비밀번호가 올바르지 않습니다.',
        code: 'INVALID_CREDENTIALS',
        statusCode: 401,
      );
    }
    throw UnimplementedError();
  }

  @override
  Future<void> requestPasswordReset(String email) async {
    resetEmail = email.trim();
  }

  @override
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    this.currentPassword = currentPassword;
    this.newPassword = newPassword;
  }
}
