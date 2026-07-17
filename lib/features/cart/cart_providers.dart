import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import 'cart_item.dart';
import 'cart_repository.dart';

final cartRepositoryProvider = Provider<CartRepository>(
  (ref) => CartRepository(ref.watch(supabaseClientProvider)),
);

class CartNotifier extends AsyncNotifier<List<CartItem>> {
  @override
  Future<List<CartItem>> build() {
    ref.watch(authStateProvider); // 로그인/로그아웃 시 갱신
    return ref.watch(cartRepositoryProvider).fetchCart();
  }

  Future<void> add(
    String productId,
    int quantity, {
    Map<String, String> selectedOptions = const {},
  }) async {
    await ref
        .read(cartRepositoryProvider)
        .addToCart(productId, quantity, selectedOptions: selectedOptions);
    ref.invalidateSelf();
  }

  Future<void> updateQuantity(String cartItemId, int quantity) async {
    await ref.read(cartRepositoryProvider).updateQuantity(cartItemId, quantity);
    ref.invalidateSelf();
  }

  Future<void> remove(String cartItemId) async {
    await ref.read(cartRepositoryProvider).removeItem(cartItemId);
    ref.invalidateSelf();
  }
}

final cartProvider =
    AsyncNotifierProvider<CartNotifier, List<CartItem>>(CartNotifier.new);

final cartItemCountProvider = Provider<int>((ref) {
  final items = ref.watch(cartProvider).value ?? [];
  return items.length;
});

/// 주문 가능한 상품들의 합계 금액
final cartTotalProvider = Provider<int>((ref) {
  final items = ref.watch(cartProvider).value ?? [];
  return items
      .where((i) => i.isOrderable)
      .fold(0, (sum, i) => sum + i.lineTotal);
});
