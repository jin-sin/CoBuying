import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'review.dart';
import 'reviews_providers.dart';
import 'widgets/rating_stars.dart';

/// 리뷰 작성/수정 다이얼로그.
/// 새로 쓸 때는 [productId]·[orderItemId], 수정할 때는 [existing]을 넘긴다.
/// 저장에 성공하면 true를 돌려주고, 관련 프로바이더는 여기서 갱신한다.
Future<bool?> showReviewFormDialog(
  BuildContext context, {
  String? productId,
  String? orderItemId,
  Review? existing,
}) {
  assert(existing != null || (productId != null && orderItemId != null));
  return showDialog<bool>(
    context: context,
    builder: (context) => _ReviewFormDialog(
      productId: existing?.productId ?? productId!,
      orderItemId: existing?.orderItemId ?? orderItemId!,
      existing: existing,
    ),
  );
}

class _ReviewFormDialog extends ConsumerStatefulWidget {
  const _ReviewFormDialog({
    required this.productId,
    required this.orderItemId,
    this.existing,
  });

  final String productId;
  final String orderItemId;
  final Review? existing;

  @override
  ConsumerState<_ReviewFormDialog> createState() => _ReviewFormDialogState();
}

class _ReviewFormDialogState extends ConsumerState<_ReviewFormDialog> {
  late int _rating = widget.existing?.rating ?? 0;
  late final _controller =
      TextEditingController(text: widget.existing?.content ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_rating == 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('별점을 선택해 주세요.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(reviewsRepositoryProvider);
      if (widget.existing != null) {
        await repo.updateReview(
          reviewId: widget.existing!.id,
          rating: _rating,
          content: _controller.text.trim(),
        );
      } else {
        await repo.addReview(
          productId: widget.productId,
          orderItemId: widget.orderItemId,
          rating: _rating,
          content: _controller.text.trim(),
        );
      }
      ref.invalidate(productReviewsProvider(widget.productId));
      ref.invalidate(productReviewStatsProvider(widget.productId));
      ref.invalidate(myReviewedItemIdsProvider);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('저장에 실패했습니다: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing != null ? '리뷰 수정' : '리뷰 작성'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RatingStarsInput(
              rating: _rating,
              onChanged: (v) => setState(() => _rating = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              maxLines: 4,
              maxLength: 500,
              decoration: const InputDecoration(
                hintText: '상품은 어떠셨나요? (선택)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '저장 중...' : '저장'),
        ),
      ],
    );
  }
}
