/// 빌드 시 --dart-define 으로 주입되는 환경 값.
///
/// flutter run --dart-define=SUPABASE_URL=https://... \
///             --dart-define=SUPABASE_ANON_KEY=...
class Env {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'http://localhost:8000',
  );

  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// OAuth 콜백용 앱 딥링크 스킴 (웹에서는 사용하지 않음)
  static const authCallbackScheme = 'io.cobuying://login-callback';

  /// 무통장입금 안내 계좌 (플랫폼 수취 계좌)
  static const bankAccountInfo = '국민은행 91102204374 (예금주: 신규리)';

  /// 토스페이먼츠 클라이언트 키 (기본값은 공개 문서용 테스트 키).
  /// 운영 전환 시 --dart-define=TOSS_CLIENT_KEY=live_ck_... 로 교체.
  /// 시크릿 키는 DB의 private.app_secrets에 있다 (schema.sql 15절).
  static const tossClientKey = String.fromEnvironment(
    'TOSS_CLIENT_KEY',
    defaultValue: 'test_ck_D5GePWvyJnrK0W0k6q8gLzN97Eoq',
  );
}
