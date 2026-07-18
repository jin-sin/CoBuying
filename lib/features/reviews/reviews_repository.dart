import 'package:supabase_flutter/supabase_flutter.dart';

import 'review.dart';

class ReviewsRepository {
  ReviewsRepository(this._client);

  final SupabaseClient _client;

  Future<List<Review>> fetchProductReviews(String productId) async {
    final rows = await _client
        .from('product_reviews')
        .select('*, review_likes(user_id)')
        .eq('product_id', productId)
        .order('created_at', ascending: false);
    return rows.map(Review.fromJson).toList();
  }

  /// 리뷰 좋아요 토글. 서버 RLS가 본인 리뷰 제외·중복 방지를 검증한다.
  Future<void> setLiked(String reviewId, bool liked) async {
    final user = _client.auth.currentUser;
    if (user == null) throw StateError('로그인이 필요합니다.');
    if (liked) {
      await _client.from('review_likes').insert({
        'review_id': reviewId,
        'user_id': user.id,
      });
    } else {
      await _client
          .from('review_likes')
          .delete()
          .eq('review_id', reviewId)
          .eq('user_id', user.id);
    }
  }

  Future<ReviewStats?> fetchStats(String productId) async {
    final row = await _client
        .from('product_review_stats')
        .select()
        .eq('product_id', productId)
        .maybeSingle();
    return row == null ? null : ReviewStats.fromJson(row);
  }

  /// 전체 상품의 평점 집계 (목록 카드 배지용, 상품 id → 집계)
  Future<Map<String, ReviewStats>> fetchAllStats() async {
    final rows = await _client.from('product_review_stats').select();
    return {
      for (final r in rows) r['product_id'] as String: ReviewStats.fromJson(r),
    };
  }

  /// 내가 리뷰를 남긴 주문 아이템 id 집합 (주문 상세의 작성 버튼 표시용)
  Future<Set<String>> fetchMyReviewedItemIds() async {
    final user = _client.auth.currentUser;
    if (user == null) return {};
    final rows = await _client
        .from('product_reviews')
        .select('order_item_id')
        .eq('user_id', user.id);
    return rows.map((r) => r['order_item_id'] as String).toSet();
  }

  /// 작성. 배송 완료된 본인 주문 아이템인지는 RLS가 검증한다.
  Future<void> addReview({
    required String productId,
    required String orderItemId,
    required int rating,
    required String content,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw StateError('로그인이 필요합니다.');
    await _client.from('product_reviews').insert({
      'product_id': productId,
      'order_item_id': orderItemId,
      'user_id': user.id,
      'rating': rating,
      'content': content,
    });
  }

  Future<void> updateReview({
    required String reviewId,
    required int rating,
    required String content,
  }) async {
    await _client
        .from('product_reviews')
        .update({'rating': rating, 'content': content}).eq('id', reviewId);
  }

  Future<void> deleteReview(String reviewId) async {
    await _client.from('product_reviews').delete().eq('id', reviewId);
  }
}
