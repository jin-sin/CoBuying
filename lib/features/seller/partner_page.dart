import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/brand.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../info/legal.dart';

/// 셀러 입점 안내 — **로그인 없이** 열리는 공개 페이지 (`/partner`).
///
/// 셀러 후보에게 링크 하나로 보낼 수 있는 곳이 필요해서 만들었다. 이전에는
/// 입점 경로가 로그인 후 팝업 메뉴 안에만 있어서, 설득을 말로만 해야 했다.
///
/// 경로를 `/seller/...`가 아니라 `/partner`로 둔 이유는 라우터의 `_authRequired`가
/// `/seller` 프리픽스를 통째로 로그인 필수로 잡기 때문이다.
class PartnerPage extends StatelessWidget {
  const PartnerPage({super.key});

  static const _steps = [
    ('입점 신청', '상호명·연락처·사업자등록번호만 입력하면 됩니다. 1분이면 끝납니다.'),
    ('승인', '운영자가 확인 후 승인합니다. 승인되면 알림으로 알려드립니다.'),
    ('상품 등록', '가격·수량·판매 기한을 정해 등록합니다. 타임세일 예약도 됩니다.'),
    ('내 링크 공유', '셀러센터에서 만든 전용 링크를 인스타·카톡에 올려 손님을 데려옵니다.'),
    ('발송과 정산', '주문이 들어오면 발송하고 운송장을 입력합니다. 대금은 계좌로 정산됩니다.'),
  ];

  static const _facts = [
    (Icons.link, '내 전용 판매 링크', '인스타 프로필·카톡 채널에 걸어둘 내 스토어 주소를 드립니다. 링크로 들어온 손님은 로그인 없이 바로 내 공동구매를 봅니다.'),
    (Icons.percent, '지금 입점하면 수수료 0%', '초기 입점 셀러 대상입니다. 요율을 바꿀 때는 최소 30일 전에 알려드리고, 이미 접수된 주문에는 소급되지 않습니다.'),
    (Icons.payments_outlined, '입점비·월 이용료 없음', '결제 수수료도 저희가 부담합니다. 파실 때 나가는 돈이 없습니다.'),
    (Icons.account_balance_outlined, '계좌는 나중에', '정산 계좌는 승인 후 등록하시면 됩니다. 신청 단계에서는 받지 않습니다.'),
    (Icons.badge_outlined, '사업자등록번호 필요', '간이과세자·신규 사업자도 신청하실 수 있습니다.'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('셀러 입점 안내')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
            children: [
              const Center(child: BrandMark(size: 64)),
              const SizedBox(height: 20),
              Text('${BusinessInfo.serviceName}에서 팔아보세요',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Text(
                '기간과 수량을 정해두고 파는 공동구매 마켓입니다.\n'
                '재고를 미리 쌓아둘 필요 없이, 모인 만큼만 준비하면 됩니다.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: mutedText),
              ),
              const SizedBox(height: 28),

              for (final (icon, title, body) in _facts)
                SoftCard(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, size: 20, color: brandOrange),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            Text(body,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: mutedText)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 24),
              Text('입점 절차', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              for (var i = 0; i < _steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                            color: brandOrange, shape: BoxShape.circle),
                        child: Text('${i + 1}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_steps[i].$1,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(_steps[i].$2,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: mutedText)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 8),
              FilledButton(
                // 로그인 필요 경로라 미로그인 상태면 라우터가 로그인으로 보낸 뒤 되돌려준다
                onPressed: () => context.push('/seller'),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text('입점 신청하기'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '문의 ${BusinessInfo.phone} · ${BusinessInfo.email}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: mutedText),
              ),
              const SizedBox(height: 16),
              Text(
                brokerNotice,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: mutedText, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
