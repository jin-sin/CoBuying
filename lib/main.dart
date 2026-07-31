import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart'
    show KakaoSdk;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/env.dart';
import 'core/theme.dart';
import 'features/maintenance/maintenance_gate.dart';
import 'features/notifications/push/push_providers.dart';
import 'features/orders/payment_result_page.dart';
import 'router/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  captureLaunchQueryParams();

  // 앱 전용: 카카오톡 앱 전환 로그인용 네이티브 SDK (웹은 Supabase OAuth 사용)
  if (!kIsWeb) {
    KakaoSdk.init(nativeAppKey: Env.kakaoNativeAppKey);
  }

  await initializeDateFormatting('ko_KR');
  await Supabase.initialize(
    url: Env.supabaseUrl,
    // 셀프호스팅 Supabase는 legacy anon key를 사용하므로 유지.
    // 새 API 키(sb_publishable_...)로 전환하면 publishableKey로 교체.
    // ignore: deprecated_member_use
    anonKey: Env.supabaseAnonKey,
  );

  runApp(const ProviderScope(child: CoBuyingApp()));
}

class CoBuyingApp extends ConsumerStatefulWidget {
  const CoBuyingApp({super.key});

  @override
  ConsumerState<CoBuyingApp> createState() => _CoBuyingAppState();
}

class _CoBuyingAppState extends ConsumerState<CoBuyingApp> {
  @override
  void initState() {
    super.initState();
    // FCM 푸시 — Firebase 미설정이면 내부에서 조용히 건너뛴다
    Future.microtask(() => ref.read(pushServiceProvider).init());
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: '오렌지맨',
      theme: buildAppTheme(),
      routerConfig: router,
      // 점검 시간대(서버 전원 스케줄)에는 전체 화면 안내로 덮는다
      builder: (context, child) =>
          MaintenanceGate(child: child ?? const SizedBox.shrink()),
      locale: const Locale('ko', 'KR'),
      supportedLocales: const [Locale('ko', 'KR'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
