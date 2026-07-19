import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/env.dart';
import '../../../firebase_options.dart';

/// FCM 푸시 — 토큰 등록/해제와 알림 탭 라우팅.
///
/// Firebase 미설정(firebase_options.dart가 자리표시 값이거나, 웹에서
/// VAPID 키 미주입) 상태에서는 init()이 조용히 빠져나가 앱은 푸시 없이
/// 그대로 동작한다. 서버 쪽 흐름은 schema.sql 25절 참고.
class PushService {
  PushService(this._client, {required this.onOpenLink});

  final SupabaseClient _client;

  /// 푸시 알림 탭 시 이동할 앱 라우트 처리 (notifications.link와 동일 형식)
  final void Function(String link) onOpenLink;

  StreamSubscription<AuthState>? _authSub;
  StreamSubscription<String>? _tokenSub;
  String? _token;

  Future<void> init() async {
    final FirebaseOptions options;
    try {
      options = DefaultFirebaseOptions.currentPlatform;
    } on UnsupportedError {
      return;
    }
    if (options.apiKey.startsWith('REPLACE')) return;
    if (kIsWeb && Env.fcmVapidKey.isEmpty) return;

    await Firebase.initializeApp(options: options);
    final messaging = FirebaseMessaging.instance;

    // 종료 상태에서 알림 탭으로 시작한 경우
    final initial = await messaging.getInitialMessage();
    _openLink(initial);
    // 백그라운드 상태에서 알림 탭으로 복귀한 경우
    FirebaseMessaging.onMessageOpenedApp.listen(_openLink);

    _tokenSub = messaging.onTokenRefresh.listen((token) {
      _token = token;
      _register(token);
    });

    // 로그인(및 앱 시작 시 기존 세션 복원)마다 이 기기 토큰을 계정에 연결
    _authSub = _client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.signedIn ||
          state.event == AuthChangeEvent.initialSession) {
        _registerCurrent(messaging);
      }
    });
    if (_client.auth.currentSession != null) {
      await _registerCurrent(messaging);
    }
  }

  void _openLink(RemoteMessage? message) {
    final link = message?.data['link'];
    if (link is String && link.isNotEmpty) onOpenLink(link);
  }

  Future<void> _registerCurrent(FirebaseMessaging messaging) async {
    if (_client.auth.currentUser == null) return;
    try {
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      final token = await messaging.getToken(
        vapidKey: kIsWeb ? Env.fcmVapidKey : null,
      );
      if (token == null) return;
      _token = token;
      await _register(token);
    } catch (e) {
      // 푸시는 부가 기능 — 실패해도 앱 흐름을 막지 않는다
      debugPrint('푸시 토큰 등록 실패: $e');
    }
  }

  Future<void> _register(String token) async {
    if (_client.auth.currentUser == null) return;
    await _client.rpc('register_push_token', params: {
      'p_token': token,
      'p_platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    });
  }

  /// 로그아웃 직전 호출 — 이 기기 토큰을 계정에서 분리해
  /// 로그아웃 후에도 이전 계정 알림이 오는 것을 막는다.
  Future<void> unregister() async {
    final token = _token;
    if (token == null || _client.auth.currentUser == null) return;
    try {
      await _client.rpc('unregister_push_token', params: {'p_token': token});
    } catch (e) {
      debugPrint('푸시 토큰 해제 실패: $e');
    }
  }

  void dispose() {
    _authSub?.cancel();
    _tokenSub?.cancel();
  }
}
