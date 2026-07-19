import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// 시안 C 공용 카드 — Material Card 대신 흰 배경 + 얇은 라인 + 16 라운드
class SoftCard extends StatelessWidget {
  const SoftCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: lineColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 둥근 상품 썸네일 (이미지 없으면 자리표시 아이콘)
class ProductThumb extends StatelessWidget {
  const ProductThumb({
    super.key,
    this.imageUrl,
    this.size = 72,
    this.radius = 12,
  });

  final String? imageUrl;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: imageUrl == null || imageUrl!.isEmpty
            ? const ColoredBox(
                color: softBg,
                child: Icon(Icons.image_outlined, color: Color(0xFFB9B1A8)),
              )
            : CachedNetworkImage(imageUrl: imageUrl!, fit: BoxFit.cover),
      ),
    );
  }
}

/// 주문 상태 색 (브랜드 오렌지와 별도의 의미 색)
({Color ink, Color bg}) orderStatusColors(String status) => switch (status) {
      'pending_payment' => (ink: const Color(0xFFB7791F), bg: const Color(0xFFFFF4DB)),
      'paid' => (ink: const Color(0xFF2563EB), bg: const Color(0xFFE8F0FE)),
      'preparing' => (ink: const Color(0xFFC24A1D), bg: const Color(0xFFFFEDE4)),
      'shipped' => (ink: const Color(0xFF0E7490), bg: const Color(0xFFE0F5FA)),
      'delivered' => (ink: const Color(0xFF15803D), bg: const Color(0xFFE5F6EA)),
      'cancelled' => (ink: const Color(0xFF6E675F), bg: const Color(0xFFF0EBE4)),
      _ => (ink: mutedText, bg: softBg),
    };

/// 상태 알약 배지
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.status});

  final String label;
  final String status;

  @override
  Widget build(BuildContext context) {
    final c = orderStatusColors(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11.5, fontWeight: FontWeight.w700, color: c.ink),
      ),
    );
  }
}

/// 빈 화면 안내 (아이콘 + 문구 + 선택 버튼)
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 140),
        Center(
          child: Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: softBg,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 34, color: const Color(0xFFB9B1A8)),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: mutedText, height: 1.5)),
        ),
        if (actionLabel != null) ...[
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton(
                onPressed: onAction, child: Text(actionLabel!)),
          ),
        ],
      ],
    );
  }
}
