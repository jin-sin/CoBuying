import 'package:flutter/foundation.dart' show kIsWeb;
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

  Future<void> signInWithKakao() => _client.auth.signInWithOAuth(
        OAuthProvider.kakao,
        redirectTo: _redirectTo,
      );

  Future<void> signInWithFacebook() => _client.auth.signInWithOAuth(
        OAuthProvider.facebook,
        redirectTo: _redirectTo,
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
