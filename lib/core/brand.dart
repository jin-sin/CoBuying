import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'service_brand.dart';
import 'theme.dart';

/// 브랜드 마크 — 오렌지 슬라이스 (시안 A).
///
/// 앱 아이콘·파비콘과 **같은 도안**이다. 원본 좌표는 100x100 단위 공간이고
/// PNG 에셋은 `tools/gen_icons.py`가 같은 수치로 그린다. 도안을 고치면
/// 이 페인터와 스크립트를 함께 맞춰야 한다 (`assets/icon/app_icon.svg` 참고).
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 72, this.plated = true});

  final double size;

  /// true면 아이콘처럼 둥근 오렌지 판 위에, false면 배경 없이 마크만.
  /// 흰 배경 위에서는 plated를 켜야 흰 껍질이 보인다.
  final bool plated;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _BrandMarkPainter(plated: plated)),
    );
  }
}

class _BrandMarkPainter extends CustomPainter {
  const _BrandMarkPainter({required this.plated});

  final bool plated;

  static const _corner = 24.0;
  static const _rindR = 32.0;
  static const _fleshR = 26.0;
  static const _spokeW = 4.0;
  static const _dotR = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 100.0;
    final c = Offset(50 * k, 50 * k);

    // 판 위에서는 껍질·칼집이 흰색, 판이 없으면 흰 배경에 묻히므로 색을 뒤집는다
    final rindColor = plated ? Colors.white : brandOrange;
    final fleshColor = plated ? brandOrange : Colors.white;

    if (plated) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(_corner * k),
        ),
        Paint()..color = brandOrange,
      );
    }
    canvas.drawCircle(c, _rindR * k, Paint()..color = rindColor);
    canvas.drawCircle(c, _fleshR * k, Paint()..color = fleshColor);

    final spoke = Paint()
      ..color = rindColor
      ..strokeWidth = _spokeW * k
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 8; i++) {
      final a = math.pi * 2 * i / 8;
      canvas.drawLine(
        c,
        c + Offset(math.cos(a), math.sin(a)) * (_fleshR * k),
        spoke,
      );
    }
    canvas.drawCircle(c, _dotR * k, Paint()..color = rindColor);
  }

  @override
  bool shouldRepaint(_BrandMarkPainter old) => old.plated != plated;
}

/// 브랜드 워드마크 — "오렌담마켓"에서 '오렌담'만 브랜드색.
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key, this.fontSize = 20});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.5,
          color: inkText,
        ),
        children: const [
          TextSpan(
              text: ServiceBrand.wordmarkHead,
              style: TextStyle(color: brandOrange)),
          TextSpan(text: ServiceBrand.wordmarkTail),
        ],
      ),
    );
  }
}
