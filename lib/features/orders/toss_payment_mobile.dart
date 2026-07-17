import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/env.dart';
import 'toss_payment.dart';

const cardPaymentSupported = true;

/// 웹뷰로 결제 브릿지 페이지(pay.html)를 열어 토스 결제창을 진행한다.
/// 성공 시 승인 파라미터를 반환 — 호출부가 confirm_card_payment RPC를 호출한다.
/// 사용자가 닫으면 [PaymentCancelled], 실패면 Exception.
Future<CardPaymentResult?> requestCardPayment({
  required BuildContext context,
  required String orderNumber,
  required String orderName,
  required int amount,
  required String customerName,
}) async {
  final payUrl = Uri.parse('${Env.webBaseUrl}/pay.html').replace(
    queryParameters: {
      'ck': Env.tossClientKey,
      'orderId': orderNumber,
      'orderName': orderName,
      'amount': '$amount',
      'customerName': customerName,
    },
  );

  final result = await Navigator.of(context).push<Map<String, String>>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _TossPayWebView(payUrl: payUrl),
    ),
  );

  if (result == null || result['code'] == 'PAY_PROCESS_CANCELED') {
    throw PaymentCancelled();
  }
  if (result.containsKey('code')) {
    throw Exception(result['message'] ?? '결제에 실패했습니다.');
  }
  final paymentKey = result['paymentKey'];
  final resultAmount = int.tryParse(result['amount'] ?? '');
  if (paymentKey == null || resultAmount == null) {
    throw Exception('결제 결과가 올바르지 않습니다.');
  }
  return (
    paymentKey: paymentKey,
    orderNumber: result['orderId'] ?? orderNumber,
    amount: resultAmount,
  );
}

class _TossPayWebView extends StatelessWidget {
  const _TossPayWebView({required this.payUrl});

  final Uri payUrl;

  @override
  Widget build(BuildContext context) {
    final base = Uri.parse(Env.webBaseUrl);
    return Scaffold(
      appBar: AppBar(title: const Text('카드 결제')),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri.uri(payUrl)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
        ),
        shouldOverrideUrlLoading: (controller, action) async {
          final url = action.request.url;
          if (url == null) return NavigationActionPolicy.ALLOW;

          // 결제 결과 리다이렉트 가로채기
          if (url.host == base.host &&
              (url.path == '/pay-success.html' ||
                  url.path == '/pay-fail.html')) {
            if (context.mounted) {
              Navigator.of(context).pop(url.queryParameters);
            }
            return NavigationActionPolicy.CANCEL;
          }

          // 카드사 앱 등 외부 앱 스킴은 시스템으로 위임
          if (!{'http', 'https', 'about'}.contains(url.scheme)) {
            try {
              await launchUrl(Uri.parse(url.toString()),
                  mode: LaunchMode.externalApplication);
            } catch (_) {
              // 미설치 앱 등 — 결제창 안에서 다른 수단 선택 가능
            }
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
      ),
    );
  }
}
