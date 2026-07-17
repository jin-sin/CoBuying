import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/widgets.dart';

import '../../core/env.dart';
import 'toss_payment.dart';

const cardPaymentSupported = true;

/// 토스 결제창(v1)을 연다. 결제 완료/실패 시 /payment/success·/payment/fail로
/// 전체 페이지 리다이렉트되고, 사용자가 창을 닫으면 [PaymentCancelled]를 던진다.
/// (리다이렉트 방식이라 성공 시 반환값 없이 페이지가 넘어간다 — 항상 null)
Future<CardPaymentResult?> requestCardPayment({
  required BuildContext context, // 웹에서는 사용하지 않음 (앱 웹뷰용)
  required String orderNumber,
  required String orderName,
  required int amount,
  required String customerName,
}) async {
  final toss =
      globalContext.callMethod('TossPayments'.toJS, Env.tossClientKey.toJS)
          as JSObject;

  // 토스는 결과 쿼리를 프래그먼트 앞에 붙인다: /?paymentKey=...#/payment/success
  // → 라우트는 프래그먼트로, 파라미터는 주소창 쿼리(Uri.base)로 전달된다.
  final origin = Uri.base.origin;
  final options = JSObject()
    ..setProperty('amount'.toJS, amount.toJS)
    ..setProperty('orderId'.toJS, orderNumber.toJS)
    ..setProperty('orderName'.toJS, orderName.toJS)
    ..setProperty('customerName'.toJS, customerName.toJS)
    ..setProperty('successUrl'.toJS, '$origin/#/payment/success'.toJS)
    ..setProperty('failUrl'.toJS, '$origin/#/payment/fail'.toJS);

  try {
    await (toss.callMethod('requestPayment'.toJS, '카드'.toJS, options)
            as JSPromise)
        .toDart;
  } catch (e) {
    // 웹 전용 파일 (dart2js/wasm 웹 타깃에서만 컴파일됨)
    // ignore: invalid_runtime_check_with_js_interop_types
    if (e is JSObject &&
        (e.getProperty('code'.toJS) as JSString?)?.toDart == 'USER_CANCEL') {
      throw PaymentCancelled();
    }
    rethrow;
  }
  return null;
}
