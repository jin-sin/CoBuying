import 'package:flutter/material.dart';

/// 비주얼 퍼스트 리디자인(시안 C) 테마.
/// 화이트 그라운드 위에 상품 사진이 주인공이 되도록 서피스 틴트를 없애고,
/// 포인트는 브랜드 오렌지 하나만 쓴다.
const brandOrange = Color(0xFFFF6B35);

/// 온이미지 카드의 하단 스크림 (흰 사진 위 흰 글자 가독성 확보)
const imageScrim = LinearGradient(
  begin: Alignment.bottomCenter,
  end: Alignment.topCenter,
  colors: [Color(0xC7180C04), Color(0x00180C04)],
  stops: [0, 0.55],
);

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: brandOrange).copyWith(
    surface: Colors.white,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: Colors.white,
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: brandOrange.withValues(alpha: 0.12),
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        // M3 시드 변환을 거치면 primary가 갈색톤이 되므로 브랜드색 고정
        backgroundColor: brandOrange,
        foregroundColor: Colors.white,
        // 최소 너비를 무한대(Size.fromHeight)로 두면 Row 등 가로 무제한
        // 레이아웃에서 버튼이 그려지지 않는다. 높이만 키우고 너비는 내용에 맡긴다.
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
  );
}
