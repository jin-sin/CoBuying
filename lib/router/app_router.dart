import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/admin/admin_home_page.dart';
import '../features/admin/product_edit_page.dart';
import '../features/auth/auth_providers.dart';
import '../features/auth/login_page.dart';
import '../features/cart/cart_page.dart';
import '../features/orders/checkout_page.dart';
import '../features/orders/order_detail_page.dart';
import '../features/orders/order_list_page.dart';
import '../features/notifications/notifications_page.dart';
import '../features/orders/payment_result_page.dart';
import '../features/products/product_detail_page.dart';
import '../features/products/product_list_page.dart';
import '../features/seller/seller_home_page.dart';

/// 로그인이 필요한 경로
const _authRequired = {
  '/cart', '/checkout', '/orders', '/seller', '/payment', '/notifications',
};

final routerProvider = Provider<GoRouter>((ref) {
  final authRepo = ref.watch(authRepositoryProvider);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: _StreamListenable(authRepo.onAuthStateChange),
    redirect: (context, state) {
      final loggedIn = authRepo.currentUser != null;
      final path = state.uri.path;

      final needsAuth = _authRequired.any((p) => path.startsWith(p)) ||
          path.startsWith('/admin');
      if (needsAuth && !loggedIn) {
        return '/login?from=${Uri.encodeComponent(state.uri.toString())}';
      }
      if (path == '/login' && loggedIn) {
        return state.uri.queryParameters['from'] ?? '/';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, _) => const ProductListPage()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(
        path: '/product/:id',
        builder: (_, state) =>
            ProductDetailPage(productId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/cart', builder: (_, _) => const CartPage()),
      GoRoute(path: '/checkout', builder: (_, _) => const CheckoutPage()),
      GoRoute(path: '/orders', builder: (_, _) => const OrderListPage()),
      GoRoute(
        path: '/orders/:id',
        builder: (_, state) => OrderDetailPage(
          orderId: state.pathParameters['id']!,
          justPlaced: state.uri.queryParameters['placed'] == '1',
        ),
      ),
      // 토스 결제창 리다이렉트 진입점. 토스는 쿼리를 프래그먼트 앞에 붙이므로
      // (/?paymentKey=...#/payment/success) 실제 주소창 쿼리(Uri.base)도 함께 읽는다.
      GoRoute(
        path: '/payment/success',
        builder: (_, state) => PaymentSuccessPage(params: {
          ...launchQueryParams,
          ...Uri.base.queryParameters,
          ...state.uri.queryParameters,
        }),
      ),
      GoRoute(
        path: '/payment/fail',
        builder: (_, state) => PaymentFailPage(params: {
          ...launchQueryParams,
          ...Uri.base.queryParameters,
          ...state.uri.queryParameters,
        }),
      ),
      GoRoute(
          path: '/notifications',
          builder: (_, _) => const NotificationsPage()),
      GoRoute(path: '/seller', builder: (_, _) => const SellerHomePage()),
      GoRoute(
          path: '/seller/product/new',
          builder: (_, _) => const ProductEditPage()),
      GoRoute(
        path: '/seller/product/:id',
        builder: (_, state) =>
            ProductEditPage(productId: state.pathParameters['id']),
      ),
      GoRoute(path: '/admin', builder: (_, _) => const AdminHomePage()),
      // 상품 등록은 셀러 전용. 관리자는 중재(수정/숨김)만 가능.
      GoRoute(
        path: '/admin/product/:id',
        builder: (_, state) =>
            ProductEditPage(productId: state.pathParameters['id']),
      ),
    ],
  );
});

/// Stream을 GoRouter의 refreshListenable로 변환
class _StreamListenable extends ChangeNotifier {
  _StreamListenable(Stream<dynamic> stream) {
    _subscription = stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
