// 웹 푸시(FCM) 서비스 워커 — 백그라운드(탭 닫힘/비활성)에서 알림을 띄운다.
// firebase_messaging이 getToken() 시 이 파일명을 자동으로 등록한다.
//
// 사용하려면 아래 firebaseConfig를 Firebase 콘솔 > 프로젝트 설정 > 웹 앱의
// 값으로 채우고 (lib/firebase_options.dart의 web과 동일 값),
// 빌드 시 --dart-define=FCM_VAPID_KEY=... 를 함께 넣어야 한다.
// 값이 자리표시(REPLACE) 그대로면 앱 쪽에서 웹 푸시를 켜지 않으므로
// 이 파일은 로드되지 않는다.
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyA6v4cIsd3v34tKyfVp7cpkHOn_4Y1SgWo',
  appId: '1:849996093275:web:7606777535d80754632c7e',
  messagingSenderId: '849996093275',
  projectId: 'cobuying-30d63',
});

firebase.messaging();
