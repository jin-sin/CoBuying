import 'package:supabase_flutter/supabase_flutter.dart';

import '../products/product.dart';

class WishlistRepository {
  WishlistRepository(this._client);

  final SupabaseClient _client;

  /// 내가 찜한 상품 id 집합 (하트 표시용)
  Future<Set<String>> fetchMyProductIds() async {
    final user = _client.auth.currentUser;
    if (user == null) return {};
    final rows = await _client
        .from('wishlists')
        .select('product_id')
        .eq('user_id', user.id);
    return rows.map((r) => r['product_id'] as String).toSet();
  }

  /// 찜 목록 페이지용 (상품 조인, 최근 찜 순)
  Future<List<Product>> fetchMyProducts() async {
    final user = _client.auth.currentUser;
    if (user == null) return [];
    final rows = await _client
        .from('wishlists')
        .select('products(*)')
        .eq('user_id', user.id)
        .order('created_at', ascending: false);
    return [
      for (final r in rows)
        if (r['products'] != null)
          Product.fromJson(r['products'] as Map<String, dynamic>),
    ];
  }

  Future<void> setWished(String productId, bool wished) async {
    final user = _client.auth.currentUser;
    if (user == null) throw StateError('로그인이 필요합니다.');
    if (wished) {
      await _client.from('wishlists').upsert({
        'user_id': user.id,
        'product_id': productId,
      });
    } else {
      await _client
          .from('wishlists')
          .delete()
          .eq('user_id', user.id)
          .eq('product_id', productId);
    }
  }
}
