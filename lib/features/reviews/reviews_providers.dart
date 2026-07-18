import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import 'review.dart';
import 'reviews_repository.dart';

final reviewsRepositoryProvider = Provider<ReviewsRepository>(
  (ref) => ReviewsRepository(ref.watch(supabaseClientProvider)),
);

final productReviewsProvider =
    FutureProvider.autoDispose.family<List<Review>, String>(
  (ref, productId) =>
      ref.watch(reviewsRepositoryProvider).fetchProductReviews(productId),
);

final productReviewStatsProvider =
    FutureProvider.autoDispose.family<ReviewStats?, String>(
  (ref, productId) => ref.watch(reviewsRepositoryProvider).fetchStats(productId),
);

/// 내가 리뷰를 남긴 주문 아이템 id 집합 (주문 상세의 작성 버튼 표시용)
final myReviewedItemIdsProvider =
    FutureProvider.autoDispose<Set<String>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(reviewsRepositoryProvider).fetchMyReviewedItemIds();
});
