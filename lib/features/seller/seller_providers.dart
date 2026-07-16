import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../orders/order.dart';
import 'seller_profile.dart';
import 'seller_repository.dart';

final sellerRepositoryProvider = Provider<SellerRepository>(
  (ref) => SellerRepository(ref.watch(supabaseClientProvider)),
);

/// 내 셀러 프로필 (미신청 시 null)
final mySellerProfileProvider = FutureProvider<SellerProfile?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(sellerRepositoryProvider).fetchMyProfile();
});

final isApprovedSellerProvider = Provider<bool>(
  (ref) => ref.watch(mySellerProfileProvider).value?.isApproved ?? false,
);

final mySalesProvider = FutureProvider.autoDispose<List<(OrderItem, Order)>>(
  (ref) => ref.watch(sellerRepositoryProvider).fetchMySales(),
);

final mySettlementProvider = FutureProvider.autoDispose<SellerSettlement>(
  (ref) => ref.watch(sellerRepositoryProvider).fetchMySettlement(),
);

/// 관리자용: 전체 셀러 목록 (페이지 재진입 시 다시 조회)
final allSellersProvider = FutureProvider.autoDispose<List<SellerProfile>>(
  (ref) => ref.watch(sellerRepositoryProvider).fetchAllSellers(),
);

/// 관리자용: 셀러별 정산 집계
final allSettlementsProvider =
    FutureProvider.autoDispose<Map<String, SellerSettlement>>(
  (ref) => ref.watch(sellerRepositoryProvider).fetchAllSettlements(),
);

/// 내 지급 내역 (셀러센터용)
final myPayoutsProvider = FutureProvider.autoDispose<List<SellerPayout>>(
  (ref) => ref.watch(sellerRepositoryProvider).fetchPayouts(),
);
