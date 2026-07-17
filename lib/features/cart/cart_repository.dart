import 'package:supabase_flutter/supabase_flutter.dart';

import 'cart_item.dart';

class CartRepository {
  CartRepository(this._client);

  final SupabaseClient _client;

  Future<List<CartItem>> fetchCart() async {
    final user = _client.auth.currentUser;
    if (user == null) return [];
    final rows = await _client
        .from('cart_items')
        .select('*, products(*)')
        .eq('user_id', user.id)
        .order('created_at');
    return rows.map(CartItem.fromJson).toList();
  }

  /// 같은 상품 + 같은 옵션 조합이 이미 담겨 있으면 수량을 더한다.
  Future<void> addToCart(
    String productId,
    int quantity, {
    Map<String, String> selectedOptions = const {},
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw const AuthException('로그인이 필요합니다.');

    // jsonb 동등 비교는 키 순서와 무관하므로 contains 양방향 대신 eq로 충분
    final existing = await _client
        .from('cart_items')
        .select('id, quantity')
        .eq('user_id', user.id)
        .eq('product_id', productId)
        .eq('selected_options', selectedOptions)
        .maybeSingle();

    if (existing == null) {
      await _client.from('cart_items').insert({
        'user_id': user.id,
        'product_id': productId,
        'quantity': quantity,
        'selected_options': selectedOptions,
      });
    } else {
      await _client
          .from('cart_items')
          .update({'quantity': (existing['quantity'] as int) + quantity})
          .eq('id', existing['id'] as String);
    }
  }

  Future<void> updateQuantity(String cartItemId, int quantity) async {
    if (quantity <= 0) {
      await removeItem(cartItemId);
    } else {
      await _client
          .from('cart_items')
          .update({'quantity': quantity})
          .eq('id', cartItemId);
    }
  }

  Future<void> removeItem(String cartItemId) async {
    await _client.from('cart_items').delete().eq('id', cartItemId);
  }
}
