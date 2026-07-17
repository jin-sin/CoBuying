/// 토스페이먼츠 결제창 호출 (웹: JS SDK 리다이렉트, 앱: 웹뷰 브릿지).
///
/// - 웹: 성공 시 /payment/success 로 전체 페이지 리다이렉트되므로 반환값이
///   없고(null), 승인은 리다이렉트 페이지에서 처리된다.
/// - 앱: 웹뷰에서 결제 완료 후 승인 파라미터를 반환한다. 호출부가
///   confirm_card_payment RPC를 호출해야 한다.
/// - 사용자가 결제창을 닫으면 양쪽 모두 [PaymentCancelled]를 던진다.
library;

export 'toss_payment_mobile.dart'
    if (dart.library.js_interop) 'toss_payment_web.dart';

/// 앱(웹뷰) 결제 성공 시 승인에 필요한 파라미터
typedef CardPaymentResult = ({
  String paymentKey,
  String orderNumber,
  int amount,
});

/// 사용자가 결제창을 닫는 등 결제를 진행하지 않았을 때 던지는 예외.
class PaymentCancelled implements Exception {}
