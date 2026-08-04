import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import 'group_buy.dart';
import 'product.dart';
import 'products_repository.dart';

final productsRepositoryProvider = Provider<ProductsRepository>(
  (ref) => ProductsRepository(ref.watch(supabaseClientProvider)),
);

/// 구매자용: 판매 중인 상품 목록
final activeProductsProvider = FutureProvider<List<Product>>(
  (ref) => ref.watch(productsRepositoryProvider).fetchActiveProducts(),
);

/// 관리자용: 전체 상품 목록 (페이지 재진입 시 다시 조회)
final allProductsProvider = FutureProvider.autoDispose<List<Product>>(
  (ref) => ref.watch(productsRepositoryProvider).fetchAllProducts(),
);

/// 셀러용: 내가 등록한 상품 목록 (페이지 재진입 시 다시 조회)
final myProductsProvider = FutureProvider.autoDispose<List<Product>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(productsRepositoryProvider).fetchMyProducts();
});

/// 공동구매 진행률 (목표 수량이 걸린 상품만). 상품 목록·상세·스토어가 공유한다.
final groupBuyProgressProvider =
    FutureProvider<Map<String, GroupBuyProgress>>(
  (ref) => ref.watch(productsRepositoryProvider).fetchGroupBuyProgress(),
);

/// 공개 스토어프론트(/s/{slug})용: 한 셀러의 상품 (마감분 포함)
final shopProductsProvider =
    FutureProvider.autoDispose.family<List<Product>, String>(
  (ref, sellerId) =>
      ref.watch(productsRepositoryProvider).fetchShopProducts(sellerId),
);

final productProvider = FutureProvider.autoDispose.family<Product?, String>(
  (ref, id) => ref.watch(productsRepositoryProvider).fetchProduct(id),
);
