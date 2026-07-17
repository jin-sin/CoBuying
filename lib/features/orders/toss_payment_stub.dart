/// 모바일 앱: 카드결제 미지원 (웹 채널 전용).
const cardPaymentSupported = false;

Future<void> requestCardPayment({
  required String orderNumber,
  required String orderName,
  required int amount,
  required String customerName,
}) =>
    throw UnsupportedError('카드결제는 웹에서만 지원됩니다.');
