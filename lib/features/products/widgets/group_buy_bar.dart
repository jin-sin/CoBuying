import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../group_buy.dart';

/// 목표 수량 달성 진행바.
///
/// 이 마켓이 인포크마켓 같은 '셀러 각자 스토어'와 다른 지점이라, 숫자를
/// 눈에 띄게 보여준다. 남은 수량이 보여야 손님이 퍼뜨릴 이유가 생긴다.
class GroupBuyBar extends StatelessWidget {
  const GroupBuyBar({
    super.key,
    required this.progress,
    this.compact = false,
    this.onImage = false,
  });

  final GroupBuyProgress progress;

  /// 상품 카드용 축소판 (막대 + 짧은 라벨)
  final bool compact;

  /// 사진 위에 얹을 때 (흰 글씨 + 반투명 트랙)
  final bool onImage;

  @override
  Widget build(BuildContext context) {
    final reached = progress.reached;
    final fg = onImage
        ? Colors.white
        : (reached ? const Color(0xFF15803D) : brandOrange);
    final track = onImage ? Colors.white.withValues(alpha: 0.35) : softBg;

    final label = reached
        ? '목표 달성 · ${progress.paidQuantity}/${progress.minQuantity}개'
        : '${progress.paidQuantity}/${progress.minQuantity}개 · '
            '${progress.remaining}개 남음';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: progress.ratio,
            minHeight: compact ? 3 : 6,
            backgroundColor: track,
            valueColor: AlwaysStoppedAnimation(fg),
          ),
        ),
        SizedBox(height: compact ? 3 : 6),
        Row(
          children: [
            if (reached) ...[
              Icon(Icons.check_circle,
                  size: compact ? 11 : 14,
                  color: onImage ? Colors.white : const Color(0xFF15803D)),
              const SizedBox(width: 3),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 10 : 12.5,
                  fontWeight: FontWeight.w700,
                  color: onImage ? Colors.white : fg,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 상품 상세용 안내 문구 — 미달 시 어떻게 되는지 미리 알려야 결제 저항이 준다.
class GroupBuyNotice extends StatelessWidget {
  const GroupBuyNotice({super.key, required this.progress});

  final GroupBuyProgress progress;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: softBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.groups_outlined, size: 18, color: brandOrange),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              progress.reached
                  ? '목표 수량을 채워 이 공동구매는 확정되었습니다. 마감 후 순차 발송됩니다.'
                  : '마감까지 ${progress.minQuantity}개가 모여야 진행되는 공동구매입니다. '
                      '못 채우면 자동으로 취소되고 결제하신 금액은 전액 환불됩니다.',
              style: const TextStyle(
                  fontSize: 12.5, color: mutedText, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
