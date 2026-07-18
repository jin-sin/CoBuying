import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../products/product.dart';
import 'wishlist_repository.dart';

final wishlistRepositoryProvider = Provider<WishlistRepository>(
  (ref) => WishlistRepository(ref.watch(supabaseClientProvider)),
);

/// 내가 찜한 상품 id 집합 (목록·상세의 하트 표시용)
final myWishlistIdsProvider = FutureProvider.autoDispose<Set<String>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(wishlistRepositoryProvider).fetchMyProductIds();
});

/// 찜 목록 페이지용
final myWishlistProductsProvider =
    FutureProvider.autoDispose<List<Product>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(wishlistRepositoryProvider).fetchMyProducts();
});
