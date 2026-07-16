import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_repository.dart';

final supabaseClientProvider =
    Provider<SupabaseClient>((ref) => Supabase.instance.client);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(supabaseClientProvider)),
);

final authStateProvider = StreamProvider<AuthState>(
  (ref) => ref.watch(authRepositoryProvider).onAuthStateChange,
);

/// 현재 로그인한 유저 (미로그인 시 null)
final currentUserProvider = Provider<User?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(authRepositoryProvider).currentUser;
});

/// 내 프로필 (관리자 여부 판단에 사용)
final myProfileProvider = FutureProvider<Map<String, dynamic>?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(authRepositoryProvider).fetchMyProfile();
});

final isAdminProvider = Provider<bool>((ref) {
  final profile = ref.watch(myProfileProvider).value;
  return profile?['role'] == 'admin';
});
