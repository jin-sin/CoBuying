import 'package:intl/intl.dart';

final _won = NumberFormat('#,###', 'ko_KR');
final _dateTime = DateFormat('yyyy.MM.dd HH:mm');

String formatWon(int amount) => '${_won.format(amount)}원';

String formatDateTime(DateTime dt) => _dateTime.format(dt.toLocal());

/// 남은 시간을 "1일 05:12:33" / "05:12:33" 형태로 표시
String formatRemaining(Duration d) {
  if (d.isNegative) return '마감';
  final days = d.inDays;
  final h = (d.inHours % 24).toString().padLeft(2, '0');
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return days > 0 ? '$days일 $h:$m:$s' : '$h:$m:$s';
}
