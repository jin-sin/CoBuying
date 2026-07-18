import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/formatters.dart';
import '../../auth/auth_providers.dart';
import '../review.dart';
import '../review_form_dialog.dart';
import '../reviews_providers.dart';
import 'rating_stars.dart';

/// 상품 상세 하단의 리뷰 목록 섹션 (평점 요약 + 리뷰 목록)
class ProductReviewsSection extends ConsumerWidget {
  const ProductReviewsSection({super.key, required this.productId});

  final String productId;

  Future<void> _toggleLike(
      BuildContext context, WidgetRef ref, Review review, bool liked) async {
    if (ref.read(currentUserProvider) == null) {
      context.push('/login');
      return;
    }
    try {
      await ref.read(reviewsRepositoryProvider).setLiked(review.id, liked);
      ref.invalidate(productReviewsProvider(productId));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('처리에 실패했습니다: $e')));
      }
    }
  }

  Future<void> _deleteReview(
      BuildContext context, WidgetRef ref, Review review) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('리뷰 삭제'),
        content: const Text('이 리뷰를 삭제할까요?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('아니요')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('삭제')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(reviewsRepositoryProvider).deleteReview(review.id);
      ref.invalidate(productReviewsProvider(productId));
      ref.invalidate(productReviewStatsProvider(productId));
      ref.invalidate(myReviewedItemIdsProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('삭제에 실패했습니다: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final reviewsAsync = ref.watch(productReviewsProvider(productId));
    final stats = ref.watch(productReviewStatsProvider(productId)).value;
    final userId = ref.watch(currentUserProvider)?.id;
    final isAdmin = ref.watch(isAdminProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('리뷰', style: theme.textTheme.titleMedium),
            if (stats != null && stats.reviewCount > 0) ...[
              const SizedBox(width: 8),
              RatingStars(rating: stats.avgRating),
              const SizedBox(width: 4),
              Text(
                '${stats.avgLabel} (${stats.reviewCount})',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: Colors.grey[600]),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        reviewsAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('리뷰를 불러오지 못했습니다.\n$e'),
          data: (reviews) {
            if (reviews.isEmpty) {
              return Text(
                '아직 리뷰가 없습니다. 배송 완료 후 주문 상세에서 첫 리뷰를 남겨보세요.',
                style:
                    theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
              );
            }
            return Column(
              children: [
                for (final review in reviews)
                  _ReviewTile(
                    review: review,
                    isMine: review.userId == userId,
                    canDelete: review.userId == userId || isAdmin,
                    liked: review.likedBy(userId),
                    onEdit: () =>
                        showReviewFormDialog(context, existing: review),
                    onDelete: () => _deleteReview(context, ref, review),
                    onLikeToggle: (liked) =>
                        _toggleLike(context, ref, review, liked),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ReviewTile extends StatelessWidget {
  const _ReviewTile({
    required this.review,
    required this.isMine,
    required this.canDelete,
    required this.liked,
    required this.onEdit,
    required this.onDelete,
    required this.onLikeToggle,
  });

  final Review review;
  final bool isMine;
  final bool canDelete;
  final bool liked;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onLikeToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RatingStars(rating: review.rating.toDouble()),
              const SizedBox(width: 8),
              Text(
                '${review.nickname}${isMine ? ' (나)' : ''} · ${formatDateTime(review.createdAt)}',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
              const Spacer(),
              if (isMine)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  tooltip: '수정',
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
              if (canDelete)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  tooltip: '삭제',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
          if (review.content.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(review.content, style: theme.textTheme.bodyMedium),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            // 본인 리뷰에는 좋아요 불가 (서버 RLS와 동일) — 개수만 표시
            child: isMine
                ? (review.likeCount > 0
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: Text('👍 도움돼요 ${review.likeCount}',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: Colors.grey[600])),
                      )
                    : const SizedBox.shrink())
                : OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      textStyle: theme.textTheme.bodySmall,
                    ),
                    icon: Icon(
                      liked ? Icons.thumb_up : Icons.thumb_up_outlined,
                      size: 14,
                    ),
                    label: Text(review.likeCount > 0
                        ? '도움돼요 ${review.likeCount}'
                        : '도움돼요'),
                    onPressed: () => onLikeToggle(!liked),
                  ),
          ),
        ],
      ),
    );
  }
}
