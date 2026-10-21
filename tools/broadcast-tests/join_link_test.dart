import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../lib/features/auth/auth_providers.dart';
import '../../lib/features/auth/login_page.dart';
import '../../lib/features/broadcast_orders/broadcast_staff_join_page.dart';
import '../../lib/router/auth_redirect.dart';

class AuthRefresh extends ChangeNotifier {
  AuthRefresh(SupabaseClient client) {
    subscription = client.auth.onAuthStateChange.listen((_) => notifyListeners());
  }
  late final StreamSubscription<AuthState> subscription;
  @override
  void dispose() {
    subscription.cancel();
    super.dispose();
  }
}

void main() {
  testWidgets('카카오 없이 링크 → 테스트 로그인 → 코드 참여 → 방송 화면', (tester) async {
    const code = '76f62bb8-d24d-4ec0-aedb-1951d91fa230';
    const seller = '4e1e3af4-3254-4f53-8fd1-6d5e3efc10ed';
    const assistant = '3510c98e-008b-4240-b346-a8d5b7dceadc';
    String? joinedCode;
    final client = SupabaseClient(
      'http://127.0.0.1:9',
      'local-test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (request.url.path == '/auth/v1/signup') {
          return http.Response(jsonEncode({
            'access_token': 'test-access-token',
            'refresh_token': 'test-refresh-token',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': assistant,
              'aud': 'authenticated',
              'role': 'authenticated',
              'is_anonymous': true,
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-09-28T00:00:00Z',
            },
          }), 200, headers: {'content-type': 'application/json'}, request: request);
        }
        if (request.url.path == '/rest/v1/rpc/broadcast_staff_join') {
          expect(request.headers['authorization'], 'Bearer test-access-token');
          joinedCode = (jsonDecode(request.body) as Map)['p_code'] as String;
          return http.Response(jsonEncode({'seller_id': seller, 'role': 'assistant'}),
              200, headers: {'content-type': 'application/json'}, request: request);
        }
        return http.Response('{}', 404,
            headers: {'content-type': 'application/json'}, request: request);
      }),
    );
    testClient = client;
    final refresh = AuthRefresh(client);
    final router = GoRouter(
      initialLocation: '/seller/broadcast/join?code=$code',
      refreshListenable: refresh,
      redirect: (_, state) =>
          authRedirect(state.uri, loggedIn: client.auth.currentUser != null),
      routes: [
        GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
        GoRoute(
          path: '/seller/broadcast/join',
          builder: (_, state) => BroadcastStaffJoinPage(
            client: client, initialCode: state.uri.queryParameters['code'],
          ),
        ),
        GoRoute(
          path: '/seller/broadcast',
          builder: (_, state) => Scaffold(
            body: Text('방송 화면 ${state.uri.queryParameters['seller']}'),
          ),
        ),
      ],
    );
    addTearDown(() {
      router.dispose();
      refresh.dispose();
      client.dispose();
    });

    await tester.pumpWidget(ProviderScope(child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    expect(find.text('방송 테스트 계정으로 로그인'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.queryParameters['from'],
        '/seller/broadcast/join?code=$code');

    await tester.tap(find.text('방송 테스트 계정으로 로그인'));
    await tester.pumpAndSettle();
    expect(find.text('방송 담당자로 참여'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, code);

    await tester.tap(find.text('방송 담당자로 참여'));
    await tester.pumpAndSettle();
    expect(joinedCode, code);
    expect(find.text('방송 화면 $seller'), findsOneWidget,
        reason: '현재 경로: ${router.routeInformationProvider.value.uri}; '
            '표시 텍스트: ${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).toList()}');
  });

  test('로그인 복귀 주소는 내부 앱 경로만 허용', () {
    expect(authRedirect(Uri.parse('/login?from=https%3A%2F%2Fevil.example'),
        loggedIn: true), '/');
    expect(authRedirect(Uri.parse('/login?from=%2F%2Fevil.example'),
        loggedIn: true), '/');
  });
}
