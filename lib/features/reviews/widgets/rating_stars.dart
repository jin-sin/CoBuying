import 'package:flutter/material.dart';

/// 별점 표시 (0.5 단위 반올림, 읽기 전용)
class RatingStars extends StatelessWidget {
  const RatingStars({super.key, required this.rating, this.size = 16});

  final double rating;
  final double size;

  @override
  Widget build(BuildContext context) {
    final half = (rating * 2).round(); // 0.5 단위
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          Icon(
            half >= (i + 1) * 2
                ? Icons.star
                : half == i * 2 + 1
                    ? Icons.star_half
                    : Icons.star_border,
            size: size,
            color: Colors.amber,
          ),
      ],
    );
  }
}

/// 별점 입력 (1~5)
class RatingStarsInput extends StatelessWidget {
  const RatingStarsInput({
    super.key,
    required this.rating,
    required this.onChanged,
    this.size = 36,
  });

  final int rating;
  final ValueChanged<int> onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          IconButton(
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(minWidth: size + 8),
            onPressed: () => onChanged(i),
            icon: Icon(
              i <= rating ? Icons.star : Icons.star_border,
              size: size,
              color: Colors.amber,
            ),
          ),
      ],
    );
  }
}
