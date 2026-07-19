// FCM 푸시용 Firebase 설정 — `flutterfire configure` 실행 시 실제 값으로
// 덮어써진다 (tools/cloudflare/push-worker/README.md 참고).
// 아래는 컴파일용 자리표시 값 — apiKey가 REPLACE로 시작하면
// PushService가 초기화를 건너뛰어 푸시 없이 동작한다.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError('이 플랫폼은 Firebase 설정이 없습니다.');
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyB324NFjPEIuAAo5suqbFVn23JUwSf_KSw',
    appId: '1:849996093275:android:630152fb24ee0bfe632c7e',
    messagingSenderId: '849996093275',
    projectId: 'cobuying-30d63',
    storageBucket: 'cobuying-30d63.firebasestorage.app',
  );
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'REPLACE_WITH_FLUTTERFIRE_CONFIGURE',
    appId: 'REPLACE',
    messagingSenderId: 'REPLACE',
    projectId: 'REPLACE',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyA6v4cIsd3v34tKyfVp7cpkHOn_4Y1SgWo',
    appId: '1:849996093275:web:7606777535d80754632c7e',
    messagingSenderId: '849996093275',
    projectId: 'cobuying-30d63',
    authDomain: 'cobuying-30d63.firebaseapp.com',
    storageBucket: 'cobuying-30d63.firebasestorage.app',
    measurementId: 'G-SJSS13GXJB',
  );
}
