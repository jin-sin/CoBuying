/// 점검 시간(서버 전원 스케줄) 설정. app_settings의 'maintenance' 키에 저장.
class MaintenanceConfig {
  const MaintenanceConfig({
    required this.enabled,
    required this.start,
    required this.end,
    required this.message,
  });

  final bool enabled;
  final String start; // "HH:mm" (기기 로컬 시간 기준)
  final String end; // "HH:mm"
  final String message;

  /// 서버 설정을 못 가져올 때의 기본값 (NAS 전원 스케줄과 동일하게 유지)
  static const fallback = MaintenanceConfig(
    enabled: true,
    start: '02:00',
    end: '08:00',
    message: 'break time ~ 지금은 서버 점검 시간이에요.\n아침에 다시 만나요!',
  );

  static int _minutes(String hhmm) {
    final parts = hhmm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  /// 현재 시각이 점검 시간대인지 (자정을 넘는 구간도 지원)
  bool isActiveAt(DateTime now) {
    if (!enabled) return false;
    final int s;
    final int e;
    try {
      s = _minutes(start);
      e = _minutes(end);
    } catch (_) {
      return false;
    }
    if (s == e) return false;
    final n = now.hour * 60 + now.minute;
    return s < e ? (n >= s && n < e) : (n >= s || n < e);
  }

  factory MaintenanceConfig.fromJson(Map<String, dynamic> json) =>
      MaintenanceConfig(
        enabled: json['enabled'] as bool? ?? false,
        start: json['start'] as String? ?? '02:00',
        end: json['end'] as String? ?? '08:00',
        message: json['message'] as String? ?? fallback.message,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'start': start,
        'end': end,
        'message': message,
      };
}
