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

  /// 카카오 네이티브 앱 키 (앱 전용 — 톡 앱 전환 로그인).
  /// 변경 시 Info.plist·AndroidManifest의 kakao{키} 스킴도 함께 바꿔야 한다.
  static const kakaoNativeAppKey = String.fromEnvironment(
    'KAKAO_NATIVE_APP_KEY',
    defaultValue: '787ca823fe97b63bea5d8163315c14c0',
  );

  /// 무통장입금 안내 계좌 (플랫폼 수취 계좌)
  static const bankAccountInfo = '국민은행 91102204374 (예금주: 신규리)';

  /// 서비스 웹 주소 — 앱 웹뷰 결제 브릿지 페이지(pay.html)가 여기서 서빙된다.
  static const webBaseUrl = String.fromEnvironment(
    'WEB_BASE_URL',
    defaultValue: 'https://shop.orange-man.xyz',
  );

  /// 웹 푸시(FCM) VAPID 공개 키 — Firebase 콘솔 > 클라우드 메시징 >
  /// 웹 푸시 인증서 (공개 키라 내장 가능). 비어 있으면 웹에서는 푸시를
  /// 켜지 않는다 (앱은 무관).
  static const fcmVapidKey = String.fromEnvironment(
    'FCM_VAPID_KEY',
    defaultValue:
        'BHjgqHxb4TIbTcoeQ96RKj7yIxykfOrmoeGtX6JHF146AOcX_vnfiujX2YeA84gIaaz1cScGezIzO2fTRhx_7f0',
  );

  /// 토스페이먼츠 클라이언트 키 (기본값은 공개 문서용 테스트 키).
  /// 운영 전환 시 --dart-define=TOSS_CLIENT_KEY=live_ck_... 로 교체.
  /// 시크릿 키는 DB의 private.app_secrets에 있다 (schema.sql 15절).
  static const tossClientKey = String.fromEnvironment(
    'TOSS_CLIENT_KEY',
    defaultValue: 'test_ck_D5GePWvyJnrK0W0k6q8gLzN97Eoq',
  );
}
