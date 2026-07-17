import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show PlatformException;
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart' as kakao;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/env.dart';

class AuthRepository {
  AuthRepository(this._client);

  final SupabaseClient _client;

  User? get currentUser => _client.auth.currentUser;

  Stream<AuthState> get onAuthStateChange => _client.auth.onAuthStateChange;

  /// 웹: 현재 페이지로 복귀 (localhost 개발/실서비스 모두 대응)
  /// 앱: 딥링크 스킴으로 복귀
  String? get _redirectTo =>
      kIsWeb ? '${Uri.base.origin}/' : Env.authCallbackScheme;

  /// 앱은 인앱 브라우저 대신 외부 브라우저로 연다.
  /// 인앱 브라우저는 로그인 후 빈 콜백 페이지가 앱 위에 남는다
  /// (세션은 딥링크로 전달되지만 브라우저가 자동으로 닫히지 않음).
  LaunchMode get _launchMode =>
      kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication;

  /// 웹: Supabase OAuth (톡 설치 시 through_talk로 톡 앱 인증).
  /// 앱: 카카오 네이티브 SDK — 카카오톡이 설치돼 있으면 브라우저 없이
  /// 톡 앱으로 바로 전환하고, 미설치면 계정 로그인으로 폴백한다.
  /// 받은 OIDC id_token으로 Supabase 세션을 만든다.
  Future<void> signInWithKakao() async {
    if (kIsWeb) {
      await _client.auth.signInWithOAuth(
        OAuthProvider.kakao,
        redirectTo: _redirectTo,
        authScreenLaunchMode: _launchMode,
        queryParams: {'through_talk': 'true'},
      );
      return;
    }

    kakao.OAuthToken token;
    if (await kakao.isKakaoTalkInstalled()) {
      try {
        token = await kakao.UserApi.instance.loginWithKakaoTalk();
      } catch (e) {
        // 톡 로그인 취소는 그대로 중단, 그 외 오류는 계정 로그인으로 폴백
        if (e is PlatformException && e.code == 'CANCELED') rethrow;
        token = await kakao.UserApi.instance.loginWithKakaoAccount();
      }
    } else {
      token = await kakao.UserApi.instance.loginWithKakaoAccount();
    }

    final idToken = token.idToken;
    if (idToken == null) {
      throw const AuthException(
          '카카오 앱에 OpenID Connect가 활성화되지 않았습니다. 개발자 콘솔을 확인하세요.');
    }
    await _client.auth.signInWithIdToken(
      provider: OAuthProvider.kakao,
      idToken: idToken,
      accessToken: token.accessToken,
    );
  }

  Future<void> signInWithFacebook() => _client.auth.signInWithOAuth(
        OAuthProvider.facebook,
        redirectTo: _redirectTo,
        authScreenLaunchMode: _launchMode,
      );

  /// 네이버는 Supabase 기본 제공 프로바이더가 아닙니다.
  /// supabase/README.md 4번 항목의 Edge Function 방식으로 연동 예정.
  Future<void> signInWithNaver() async {
    throw UnimplementedError('네이버 로그인은 준비 중입니다.');
  }

  Future<void> signOut() => _client.auth.signOut();

  /// 내 프로필 (role 포함). 없으면 null.
  Future<Map<String, dynamic>?> fetchMyProfile() async {
    final user = currentUser;
    if (user == null) return null;
    return _client.from('profiles').select().eq('id', user.id).maybeSingle();
  }
}
