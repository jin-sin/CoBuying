import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/formatters.dart';

/// 판매 마감까지 남은 시간을 1초 단위로 갱신해 보여주는 배지.
/// [onImage]가 켜지면 사진 위에 올라가는 반투명 다크 칩 스타일로 그려진다.
class CountdownBadge extends StatefulWidget {
  const CountdownBadge({
    super.key,
    required this.endsAt,
    this.compact = false,
    this.onImage = false,
  });

  final DateTime endsAt;
  final bool compact;
  final bool onImage;

  @override
  State<CountdownBadge> createState() => _CountdownBadgeState();
}

class _CountdownBadgeState extends State<CountdownBadge> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.endsAt.difference(DateTime.now());
    final expired = remaining.isNegative;
    final urgent = !expired && remaining < const Duration(hours: 3);

    if (widget.onImage) {
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: widget.compact ? 7 : 10,
          vertical: widget.compact ? 3 : 5,
        ),
        decoration: BoxDecoration(
          color: urgent
              ? const Color(0xE6E5310B) // 임박: 진한 레드-오렌지
              : Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined,
                size: widget.compact ? 11 : 13, color: Colors.white),
            const SizedBox(width: 3),
            Text(
              expired ? '마감' : formatRemaining(remaining),
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: widget.compact ? 10 : 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );
    }

    final color = expired
        ? Colors.grey
        : urgent
            ? Colors.red
            : Theme.of(context).colorScheme.primary;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: widget.compact ? 8 : 12,
        vertical: widget.compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: widget.compact ? 14 : 18, color: color),
          const SizedBox(width: 4),
          Text(
            expired ? '판매 마감' : '${formatRemaining(remaining)} 남음',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: widget.compact ? 12 : 14,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
