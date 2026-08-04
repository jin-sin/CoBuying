import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/formatters.dart';
import '../../../core/theme.dart';
import '../../reviews/review.dart';
import '../group_buy.dart';
import '../product.dart';
import 'countdown_badge.dart';
import 'group_buy_bar.dart';

/// 상품 카드 — 시안 C: 정보가 사진 위로 (하단 스크림 + 온이미지 텍스트).
/// 홈 그리드와 찜 목록에서 함께 쓴다.
class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.product,
    this.stats,
    this.wished = false,
    this.onWishToggle,
    this.progress,
  });

  final Product product;
  final ReviewStats? stats;
  final bool wished;
  final ValueChanged<bool>? onWishToggle;

  /// 목표 수량이 걸린 공동구매면 진행바를 사진 위에 얹는다
  final GroupBuyProgress? progress;

  @override
  Widget build(BuildContext context) {
    final pct = product.isOnTimeSale
        ? product.saleDiscountRate
        : product.discountRate;
    final ended = !product.isOnSale;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ProductImage(product: product),
          const DecoratedBox(
              decoration: BoxDecoration(gradient: imageScrim)),
          // 판매 종료 상품은 살짝 바래게 (찜 목록에서 재판매 대기용으로 남음)
          if (ended)
            const DecoratedBox(
                decoration: BoxDecoration(color: Color(0x8FFFFFFF))),
          Positioned(
            top: 8,
            left: 8,
            child: CountdownBadge(
                endsAt: product.endsAt, compact: true, onImage: true),
          ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 9,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  product.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.88),
                    fontSize: 10.5,
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    if (pct != null) ...[
                      Text(
                        '$pct%',
                        style: const TextStyle(
                          color: Color(0xFFFFB08A),
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(width: 5),
                    ],
                    Flexible(
                      child: Text(
                        formatWon(product.effectivePrice),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                if (progress != null && progress!.hasGoal) ...[
                  const SizedBox(height: 5),
                  GroupBuyBar(
                      progress: progress!, compact: true, onImage: true),
                ],
                if (stats != null && stats!.reviewCount > 0)
                  Row(
                    children: [
                      const Icon(Icons.star_rounded,
                          size: 11, color: Color(0xFFFFC94D)),
                      const SizedBox(width: 2),
                      Text(
                        '${stats!.avgLabel} (${stats!.reviewCount})',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 9.5,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => context.push('/product/${product.id}'),
            ),
          ),
          // 하트는 잉크웰 위에 — 카드 탭과 분리
          if (onWishToggle != null)
            Positioned(
              top: 6,
              right: 6,
              child: Material(
                color: Colors.white.withValues(alpha: 0.85),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => onWishToggle?.call(!wished),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(
                      wished ? Icons.favorite : Icons.favorite_border,
                      size: 15,
                      color: wished ? Colors.red : const Color(0xFF6E675F),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 상품 대표 이미지 (없으면 회색 자리표시)
class ProductImage extends StatelessWidget {
  const ProductImage({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    if (product.imageUrls.isEmpty) {
      return const ColoredBox(
        color: softBg,
        child: Icon(Icons.image_outlined,
            size: 40, color: Color(0xFFB9B1A8)),
      );
    }
    return CachedNetworkImage(
      imageUrl: product.imageUrls.first,
      fit: BoxFit.cover,
      errorWidget: (_, _, _) => const Icon(Icons.broken_image_outlined),
    );
  }
}
