import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/formatters.dart';

/// 판매 마감까지 남은 시간을 1초 단위로 갱신해 보여주는 배지.
class CountdownBadge extends StatefulWidget {
  const CountdownBadge({super.key, required this.endsAt, this.compact = false});

  final DateTime endsAt;
  final bool compact;

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
