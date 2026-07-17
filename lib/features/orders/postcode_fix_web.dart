import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

String _lastPostCode = '';
bool _installed = false;

/// 마지막 주소 검색에서 가로챈 우편번호.
String get lastSearchedPostCode => _lastPostCode;

/// 주소 검색을 열기 전에 호출: 이전 값을 비우고 리스너를 1회 등록한다.
void beginPostcodeCapture() {
  _lastPostCode = '';
  if (_installed) return;
  _installed = true;

  final document = globalContext.getProperty('document'.toJS) as JSObject;
  document.callMethod(
    'addEventListener'.toJS,
    'kpostalResult'.toJS,
    ((JSObject event) {
      try {
        final detail = (event.getProperty('detail'.toJS) as JSString?)?.toDart;
        if (detail == null) return;
        final json = jsonDecode(detail) as Map<String, dynamic>;
        _lastPostCode =
            (json['postCode'] ?? json['zonecode'] ?? '').toString();
      } catch (_) {
        // 이벤트 형식이 바뀌어도 주소 검색 자체는 계속 동작해야 한다
      }
    }).toJS,
  );
}
