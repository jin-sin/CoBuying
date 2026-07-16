class Product {
  const Product({
    required this.id,
    this.sellerId,
    this.shopName = '',
    required this.title,
    required this.description,
    required this.price,
    this.originalPrice,
    required this.stock,
    required this.imageUrls,
    required this.startsAt,
    required this.endsAt,
    required this.status,
  });

  final String id;
  final String? sellerId;
  final String shopName; // 등록 시점 상호명 스냅샷 (DB 트리거가 채움)
  final String title;
  final String description;
  final int price;
  final int? originalPrice;
  final int stock;
  final List<String> imageUrls;
  final DateTime startsAt;
  final DateTime endsAt;
  final String status; // active | closed | hidden

  bool get isExpired => DateTime.now().isAfter(endsAt);
  bool get isOnSale => status == 'active' && !isExpired && stock > 0;

  int? get discountRate {
    final original = originalPrice;
    if (original == null || original <= price) return null;
    return ((original - price) / original * 100).round();
  }

  factory Product.fromJson(Map<String, dynamic> json) => Product(
        id: json['id'] as String,
        sellerId: json['seller_id'] as String?,
        shopName: json['shop_name'] as String? ?? '',
        title: json['title'] as String,
        description: json['description'] as String? ?? '',
        price: json['price'] as int,
        originalPrice: json['original_price'] as int?,
        stock: json['stock'] as int,
        imageUrls: (json['image_urls'] as List<dynamic>? ?? []).cast<String>(),
        startsAt: DateTime.parse(json['starts_at'] as String),
        endsAt: DateTime.parse(json['ends_at'] as String),
        status: json['status'] as String,
      );

  Map<String, dynamic> toInsertJson() => {
        'title': title,
        'description': description,
        'price': price,
        'original_price': originalPrice,
        'stock': stock,
        'image_urls': imageUrls,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'ends_at': endsAt.toUtc().toIso8601String(),
        'status': status,
      };
}
