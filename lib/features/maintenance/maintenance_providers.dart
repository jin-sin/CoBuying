import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_providers.dart';
import 'maintenance.dart';

const _cacheKey = 'maintenance_config';

class MaintenanceRepository {
  MaintenanceRepository(this._ref);

  final Ref _ref;

  /// 서버에서 설정 조회 → 성공 시 로컬 캐시.
  /// 실패(서버 꺼짐)하면 캐시 → 그것도 없으면 코드 기본값.
  Future<MaintenanceConfig> fetch() async {
    try {
      final row = await _ref
          .read(supabaseClientProvider)
          .from('app_settings')
          .select('value')
          .eq('key', 'maintenance')
          .maybeSingle()
          .timeout(const Duration(seconds: 5));
      if (row == null) return MaintenanceConfig.fallback;
      final config =
          MaintenanceConfig.fromJson(row['value'] as Map<String, dynamic>);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(config.toJson()));
      return config;
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null) {
        try {
          return MaintenanceConfig.fromJson(
              jsonDecode(cached) as Map<String, dynamic>);
        } catch (_) {}
      }
      return MaintenanceConfig.fallback;
    }
  }

  Future<void> save(MaintenanceConfig config) async {
    await _ref.read(supabaseClientProvider).from('app_settings').upsert({
      'key': 'maintenance',
      'value': config.toJson(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, jsonEncode(config.toJson()));
  }
}

final maintenanceRepositoryProvider =
    Provider<MaintenanceRepository>(MaintenanceRepository.new);

final maintenanceConfigProvider = FutureProvider<MaintenanceConfig>(
  (ref) => ref.watch(maintenanceRepositoryProvider).fetch(),
);

/// 1분마다 현재 시각으로 점검 여부 재평가
final _tickProvider = StreamProvider<DateTime>(
  (ref) => Stream.periodic(const Duration(minutes: 1), (_) => DateTime.now()),
);

/// 관리자가 잘못 설정해 잠기는 것을 막는 세션 한정 우회 스위치
class MaintenanceBypass extends Notifier<bool> {
  @override
  bool build() => false;

  void enable() => state = true;
}

final maintenanceBypassProvider =
    NotifierProvider<MaintenanceBypass, bool>(MaintenanceBypass.new);

final maintenanceActiveProvider = Provider<bool>((ref) {
  if (ref.watch(maintenanceBypassProvider)) return false;
  final config = ref.watch(maintenanceConfigProvider).value;
  if (config == null) return false; // 로딩 중에는 막지 않는다
  final now = ref.watch(_tickProvider).value ?? DateTime.now();
  return config.isActiveAt(now);
});
