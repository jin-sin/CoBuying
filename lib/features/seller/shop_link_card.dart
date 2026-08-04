import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/env.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'seller_profile.dart';
import 'seller_providers.dart';

/// 셀러센터의 '내 판매 링크' 카드.
///
/// 신규 마켓엔 트래픽이 없다는 게 입점을 막는 가장 큰 이유라, 셀러가 자기 손님을
/// 데려올 주소를 먼저 쥐어준다. 미설정이면 만들라고 권하고, 설정돼 있으면
/// 복사·열기만 남긴다.
class ShopLinkCard extends ConsumerWidget {
  const ShopLinkCard({super.key, required this.profile});

  final SellerProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slug = profile.slug;

    return SoftCard(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.link, size: 18, color: brandOrange),
              const SizedBox(width: 8),
              const Text('내 판매 링크',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              if (slug != null)
                TextButton(
                  onPressed: () => _edit(context, ref),
                  child: const Text('변경'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (slug == null) ...[
            const Text(
              '인스타 프로필·카톡 채널에 걸어둘 내 스토어 주소를 만드세요. '
              '링크로 들어온 손님은 로그인 없이 바로 내 공동구매를 봅니다.',
              style: TextStyle(fontSize: 13, color: mutedText, height: 1.5),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _edit(context, ref),
              icon: const Icon(Icons.add_link, size: 18),
              label: const Text('판매 링크 만들기'),
            ),
          ] else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: softBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                shopUrl(slug),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: shopUrl(slug)));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('링크를 복사했습니다.')));
                      }
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('복사'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/s/$slug'),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('열기'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ShopLinkDialog(current: profile.slug),
    );
    if (saved == true) ref.invalidate(mySellerProfileProvider);
  }
}

class _ShopLinkDialog extends ConsumerStatefulWidget {
  const _ShopLinkDialog({this.current});

  final String? current;

  @override
  ConsumerState<_ShopLinkDialog> createState() => _ShopLinkDialogState();
}

class _ShopLinkDialogState extends ConsumerState<_ShopLinkDialog> {
  late final _controller = TextEditingController(text: widget.current ?? '');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _controller.text.trim().toLowerCase();
    // 서버(set_my_shop_slug)가 같은 규칙으로 다시 검사한다 — 여기선 왕복을 아끼는 용도
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{1,19}$').hasMatch(value)) {
      setState(() => _error = '영문 소문자·숫자·하이픈 2~20자로 입력해 주세요.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(sellerRepositoryProvider).setShopSlug(value);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = _message(e);
      });
    }
  }

  /// PostgrestException은 message에 DB가 raise한 한글 문구를 그대로 담아온다
  String _message(Object e) {
    final raw = e.toString();
    final i = raw.indexOf('message: ');
    return i == -1 ? raw : raw.substring(i + 9).split(',').first;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('판매 링크 주소'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_saving,
            autocorrect: false,
            decoration: InputDecoration(
              prefixText: '${Env.webBaseUrl.replaceFirst('https://', '')}/s/',
              prefixStyle: const TextStyle(fontSize: 13, color: mutedText),
              hintText: 'my-shop',
              errorText: _error,
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          const Text(
            '영문 소문자·숫자·하이픈 2~20자. 상호명이나 인스타 아이디와 맞추면 기억하기 쉽습니다.',
            style: TextStyle(fontSize: 12, color: mutedText, height: 1.4),
          ),
          if (widget.current != null) ...[
            const SizedBox(height: 8),
            const Text(
              '주소를 바꾸면 이전 주소로 공유해 둔 링크는 열리지 않습니다.',
              style: TextStyle(fontSize: 12, color: brandOrange, height: 1.4),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('저장'),
        ),
      ],
    );
  }
}
