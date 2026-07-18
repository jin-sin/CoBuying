class Review {
  const Review({
    required this.id,
    required this.productId,
    required this.orderItemId,
    required this.userId,
    required this.nickname,
    required this.rating,
    required this.content,
    required this.createdAt,
  });

  final String id;
  final String productId;
  final String orderItemId;
  final String userId;
  final String nickname; // 작성 시점 마스킹 스냅샷 (예: "김**")
  final int rating; // 1~5
  final String content;
  final DateTime createdAt;

  factory Review.fromJson(Map<String, dynamic> json) => Review(
        id: json['id'] as String,
        productId: json['product_id'] as String,
        orderItemId: json['order_item_id'] as String,
        userId: json['user_id'] as String,
        nickname: json['nickname'] as String? ?? '',
        rating: json['rating'] as int,
        content: json['content'] as String? ?? '',
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

class ReviewStats {
  const ReviewStats({required this.reviewCount, required this.avgRating});

  final int reviewCount;
  final double avgRating;

  factory ReviewStats.fromJson(Map<String, dynamic> json) => ReviewStats(
        reviewCount: json['review_count'] as int,
        avgRating: (json['avg_rating'] as num).toDouble(),
      );
}
