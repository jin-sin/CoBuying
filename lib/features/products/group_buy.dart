/// 공동구매 목표 수량 진행률 (`product_progress` 뷰 한 행).
///
/// 모인 수량은 **입금 완료 이후** 주문만 센다 — 실제 돈이 들어온 수요라야
/// 셀러가 발주할 근거가 되기 때문이다. 그래서 무통장 주문은 입금 전까지
/// 진행률에 반영되지 않는다 (schema.sql 30절).
class GroupBuyProgress {
  const GroupBuyProgress({
    required this.productId,
    required this.minQuantity,
    required this.paidQuantity,
  });

  final String productId;
  final int minQuantity;
  final int paidQuantity;

  bool get hasGoal => minQuantity > 0;
  bool get reached => paidQuantity >= minQuantity;

  /// 남은 수량 (달성했으면 0)
  int get remaining =>
      paidQuantity >= minQuantity ? 0 : minQuantity - paidQuantity;

  /// 0.0~1.0. 진행바용이라 1을 넘지 않게 자른다.
  double get ratio {
    if (minQuantity <= 0) return 0;
    final r = paidQuantity / minQuantity;
    return r > 1 ? 1 : r;
  }

  int get percent => (ratio * 100).round();

  factory GroupBuyProgress.fromJson(Map<String, dynamic> json) =>
      GroupBuyProgress(
        productId: json['product_id'] as String,
        minQuantity: (json['min_quantity'] as num?)?.toInt() ?? 0,
        paidQuantity: (json['paid_quantity'] as num?)?.toInt() ?? 0,
      );
}
