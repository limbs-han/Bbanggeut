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

  test('신규 회원은 연결 기기가 없으면 최초 기기 등록이 필요하다', () async {
    final controller = AppController(api: _AccountApiClient());

    expect(
      await controller.signUp('새 사용자', 'new@example.com', 'password-10'),
      isTrue,
    );
    expect(controller.authenticated, isTrue);
    expect(controller.selectedDevice, isNull);
    expect(controller.requiresInitialDeviceRegistration, isTrue);
    controller.dispose();
  });

  test('기존 계정은 연결 기기가 없어도 홈 화면으로 진입한다', () async {
    final controller = AppController(api: _AccountApiClient());

    expect(await controller.login('member@example.com', 'password-10'), isTrue);
    expect(controller.authenticated, isTrue);
    expect(controller.selectedDevice, isNull);
    expect(controller.requiresInitialDeviceRegistration, isFalse);
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
    return _session(email);
  }

  @override
  Future<AuthSession> signUp(
    String name,
    String email,
    String password, {
    bool persistSession = true,
  }) async => _session(email, displayName: name);

  @override
  Future<List<Invitation>> listMyInvitations() async => const [];

  @override
  Future<List<MemoryVault>> listVaults() async => const [];

  AuthSession _session(String email, {String displayName = '사용자'}) {
    return AuthSession(
      accessToken: 'access',
      refreshToken: 'refresh',
      expiresIn: 3600,
      user: UserProfile(
        id: 'user-1',
        email: email.trim(),
        displayName: displayName,
      ),
    );
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
