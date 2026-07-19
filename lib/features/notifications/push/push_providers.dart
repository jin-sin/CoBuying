import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../router/app_router.dart';
import '../../auth/auth_providers.dart';
import 'push_service.dart';

final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(
    ref.watch(supabaseClientProvider),
    // 푸시 알림 탭 → 인앱 알림과 동일하게 link 라우트로 이동
    onOpenLink: (link) => ref.read(routerProvider).push(link),
  );
  ref.onDispose(service.dispose);
  return service;
});
