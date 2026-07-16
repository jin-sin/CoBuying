import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import 'product.dart';
import 'products_repository.dart';

final productsRepositoryProvider = Provider<ProductsRepository>(
  (ref) => ProductsRepository(ref.watch(supabaseClientProvider)),
);

/// 구매자용: 판매 중인 상품 목록
final activeProductsProvider = FutureProvider<List<Product>>(
  (ref) => ref.watch(productsRepositoryProvider).fetchActiveProducts(),
);

/// 관리자용: 전체 상품 목록
final allProductsProvider = FutureProvider<List<Product>>(
  (ref) => ref.watch(productsRepositoryProvider).fetchAllProducts(),
);

/// 셀러용: 내가 등록한 상품 목록
final myProductsProvider = FutureProvider<List<Product>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(productsRepositoryProvider).fetchMyProducts();
});

final productProvider = FutureProvider.family<Product?, String>(
  (ref, id) => ref.watch(productsRepositoryProvider).fetchProduct(id),
);
