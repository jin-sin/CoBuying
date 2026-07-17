/// postal_ko 1.1.0 웹 버그 보정.
///
/// 웹 구현은 결과 JSON을 `postCode` 키로 보내는데 Kpostal.fromJson은
/// `zonecode` 키를 찾아서, 웹에서만 우편번호가 빈 값으로 온다.
/// 패키지가 document에 쏘는 kpostalResult 이벤트의 원본 JSON을 가로채
/// 우편번호를 따로 보관해 두고, 결과의 postCode가 비어 있으면 이 값을 쓴다.
library;

export 'postcode_fix_stub.dart'
    if (dart.library.js_interop) 'postcode_fix_web.dart';
