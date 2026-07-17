import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'orders_providers.dart';

/// 앱 시작 시점의 주소창 쿼리 (main()에서 캡처).
/// 토스 결제 리다이렉트 파라미터는 프래그먼트 밖 실제 쿼리로 오는데
/// (/?paymentKey=...#/payment/success), 라우터가 이후 URL을 정리할 수
/// 있으므로 시작 시점 값을 보존해 둔다.
Map<String, String> launchQueryParams = const {};

void captureLaunchQueryParams() {
  launchQueryParams = Map.unmodifiable(Uri.base.queryParameters);
}

/// 토스 결제창 성공 리다이렉트(/payment/success?paymentKey=...&orderId=...&amount=...)
/// 진입점. 서버 승인 RPC를 호출하고 완료되면 주문 상세로 이동한다.
class PaymentSuccessPage extends ConsumerStatefulWidget {
  const PaymentSuccessPage({super.key, required this.params});

  /// 토스가 successUrl에 붙여준 쿼리 파라미터
  final Map<String, String> params;

  @override
  ConsumerState<PaymentSuccessPage> createState() => _PaymentSuccessPageState();
}

class _PaymentSuccessPageState extends ConsumerState<PaymentSuccessPage> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _confirm();
  }

  Future<void> _confirm() async {
    final paymentKey = widget.params['paymentKey'];
    final orderNumber = widget.params['orderId'];
    final amount = int.tryParse(widget.params['amount'] ?? '');
    if (paymentKey == null || orderNumber == null || amount == null) {
      setState(() => _error = '결제 정보가 올바르지 않습니다.');
      return;
    }
    try {
      final orderId =
          await ref.read(ordersRepositoryProvider).confirmCardPayment(
                orderNumber: orderNumber,
                paymentKey: paymentKey,
                amount: amount,
              );
      ref.invalidate(myOrdersProvider);
      ref.invalidate(orderProvider(orderId));
      if (!mounted) return;
      context.go('/orders/$orderId?placed=1');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('결제 처리')),
      body: Center(
        child: _error == null
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('결제를 승인하고 있어요...'),
                ],
              )
            : _PaymentErrorView(
                title: '결제 승인에 실패했습니다',
                message: _error!,
              ),
      ),
    );
  }
}

/// 토스 결제창 실패 리다이렉트(/payment/fail?code=...&message=...) 진입점.
class PaymentFailPage extends StatelessWidget {
  const PaymentFailPage({super.key, required this.params});

  final Map<String, String> params;

  @override
  Widget build(BuildContext context) {
    final cancelled = params['code'] == 'PAY_PROCESS_CANCELED';
    return Scaffold(
      appBar: AppBar(title: const Text('결제 실패')),
      body: Center(
        child: _PaymentErrorView(
          title: cancelled ? '결제를 취소했어요' : '결제에 실패했습니다',
          message: cancelled
              ? '주문은 결제 대기 상태로 남아 있어요.\n주문 내역에서 다시 결제할 수 있습니다.'
              : (params['message'] ?? '알 수 없는 오류가 발생했습니다.'),
        ),
      ),
    );
  }
}

class _PaymentErrorView extends StatelessWidget {
  const _PaymentErrorView({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go('/orders'),
              child: const Text('주문 내역 보기'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => context.go('/'),
              child: const Text('홈으로'),
            ),
          ],
        ),
      ),
    );
  }
}
