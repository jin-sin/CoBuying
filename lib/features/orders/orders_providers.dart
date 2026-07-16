import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import 'order.dart';
import 'orders_repository.dart';

final ordersRepositoryProvider = Provider<OrdersRepository>(
  (ref) => OrdersRepository(ref.watch(supabaseClientProvider)),
);

final myOrdersProvider = FutureProvider.autoDispose<List<Order>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(ordersRepositoryProvider).fetchMyOrders();
});

final orderProvider = FutureProvider.autoDispose.family<Order?, String>(
  (ref, id) => ref.watch(ordersRepositoryProvider).fetchOrder(id),
);

/// 관리자용 (페이지 재진입 시 다시 조회)
final allOrdersProvider = FutureProvider.autoDispose<List<Order>>(
  (ref) => ref.watch(ordersRepositoryProvider).fetchAllOrders(),
);
