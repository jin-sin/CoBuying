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

  /// 무통장입금 안내 계좌
  static const bankAccountInfo = '국민은행 000000-00-000000 (예금주: 홍길동)';
}
