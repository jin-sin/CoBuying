/// 토스페이먼츠 결제창 호출 — 웹에서만 지원.
/// 성공/실패 시 successUrl·failUrl로 전체 페이지 리다이렉트되므로
/// 호출 이후 코드는 사용자가 결제창을 닫았을 때(PaymentCancelled)만 실행된다.
library;

export 'toss_payment_stub.dart'
    if (dart.library.js_interop) 'toss_payment_web.dart';

/// 사용자가 결제창을 닫는 등 결제를 진행하지 않았을 때 던지는 예외.
class PaymentCancelled implements Exception {}
