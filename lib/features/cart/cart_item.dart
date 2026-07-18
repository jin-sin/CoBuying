import '../products/product.dart';

class CartItem {
  const CartItem({
    required this.id,
    required this.productId,
    required this.quantity,
    required this.product,
    this.selectedOptions = const {},
  });

  final String id;
  final String productId;
  final int quantity;

  /// 선택한 옵션 {그룹명: 선택지명}. 옵션 없는 상품이면 빈 맵.
  final Map<String, String> selectedOptions;

  /// 조인으로 함께 조회한 상품 정보 (삭제된 상품이면 null)
  final Product? product;

  /// 옵션 추가금이 합산된 단가 (타임세일 중이면 세일가 기준)
  int get unitPrice =>
      (product?.effectivePrice ?? 0) +
      (product?.optionExtra(selectedOptions) ?? 0);

  int get lineTotal => unitPrice * quantity;

  bool get isOrderable => product?.isOnSale ?? false;

  /// "사이즈: L · 색상: 검정" 형태 표시용
  String get optionsLabel =>
      selectedOptions.entries.map((e) => '${e.key}: ${e.value}').join(' · ');

  factory CartItem.fromJson(Map<String, dynamic> json) => CartItem(
        id: json['id'] as String,
        productId: json['product_id'] as String,
        quantity: json['quantity'] as int,
        selectedOptions: (json['selected_options'] as Map<String, dynamic>? ??
                const {})
            .map((k, v) => MapEntry(k, v.toString())),
        product: json['products'] == null
            ? null
            : Product.fromJson(json['products'] as Map<String, dynamic>),
      );
}
