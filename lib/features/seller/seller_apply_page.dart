import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'seller_profile.dart';
import 'seller_providers.dart';

/// 셀러 입점 신청 / 정보 수정 폼.
/// [existing]이 있으면 수정 모드.
class SellerApplyPage extends ConsumerStatefulWidget {
  const SellerApplyPage({super.key, this.existing});

  final SellerProfile? existing;

  @override
  ConsumerState<SellerApplyPage> createState() => _SellerApplyPageState();
}

class _SellerApplyPageState extends ConsumerState<SellerApplyPage> {
  final _formKey = GlobalKey<FormState>();
  late final _shopName = TextEditingController(text: widget.existing?.shopName);
  late final _bankName = TextEditingController(text: widget.existing?.bankName);
  late final _bankAccount =
      TextEditingController(text: widget.existing?.bankAccount);
  late final _accountHolder =
      TextEditingController(text: widget.existing?.accountHolder);
  late final _contactPhone =
      TextEditingController(text: widget.existing?.contactPhone);
  late final _businessNumber =
      TextEditingController(text: widget.existing?.businessNumber);
  late final _onlineSalesNumber =
      TextEditingController(text: widget.existing?.onlineSalesNumber);
  bool _submitting = false;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    for (final c in [
      _shopName, _bankName, _bankAccount, _accountHolder, _contactPhone,
      _businessNumber, _onlineSalesNumber,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final repo = ref.read(sellerRepositoryProvider);
      if (_isEdit) {
        await repo.updateInfo(
          shopName: _shopName.text.trim(),
          bankName: _bankName.text.trim(),
          bankAccount: _bankAccount.text.trim(),
          accountHolder: _accountHolder.text.trim(),
          contactPhone: _contactPhone.text.trim(),
          businessNumber: _businessNumber.text.trim(),
          onlineSalesNumber: _onlineSalesNumber.text.trim(),
        );
      } else {
        await repo.apply(
          shopName: _shopName.text.trim(),
          contactPhone: _contactPhone.text.trim(),
          businessNumber: _businessNumber.text.trim(),
          onlineSalesNumber: _onlineSalesNumber.text.trim(),
        );
      }
      ref.invalidate(mySellerProfileProvider);
      if (!mounted) return;
      if (_isEdit) {
        Navigator.of(context).pop();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('입점 신청이 접수되었습니다. 관리자 승인을 기다려 주세요.')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('저장에 실패했습니다: $e')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? '필수 입력입니다' : null;

  /// 사업자등록번호 10자리 체크섬 검증 (국세청 검증 로직)
  String? _validateBusinessNumber(String? v) {
    final digits = v?.trim() ?? '';
    if (digits.isEmpty) return '필수 입력입니다';
    if (digits.length != 10) return '숫자 10자리를 입력하세요';
    const weights = [1, 3, 7, 1, 3, 7, 1, 3, 5];
    var sum = 0;
    for (var i = 0; i < 9; i++) {
      sum += int.parse(digits[i]) * weights[i];
    }
    sum += (int.parse(digits[8]) * 5) ~/ 10;
    if ((10 - sum % 10) % 10 != int.parse(digits[9])) {
      return '올바르지 않은 사업자등록번호입니다';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '셀러 정보 수정' : '셀러 입점 신청')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (!_isEdit) ...[
                  Text('상품을 판매하려면 입점 신청이 필요합니다.\n'
                      '정산 계좌는 승인 후에 등록하시면 됩니다.',
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 20),
                ],
                TextFormField(
                  controller: _shopName,
                  decoration: const InputDecoration(labelText: '상호명 (판매자명) *'),
                  validator: _required,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _contactPhone,
                  decoration: const InputDecoration(
                      labelText: '연락처 *', hintText: '숫자만 입력'),
                  keyboardType: TextInputType.phone,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: _required,
                ),
                const SizedBox(height: 24),
                Text('사업자 정보', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _businessNumber,
                  decoration: const InputDecoration(
                      labelText: '사업자등록번호 *',
                      hintText: '숫자 10자리 (- 제외)'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(10),
                  ],
                  validator: _validateBusinessNumber,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _onlineSalesNumber,
                  decoration: const InputDecoration(
                      labelText: '통신판매업 신고번호 (선택)',
                      hintText: '예: 2026-서울강남-01234'),
                ),
                if (!_isEdit) ...[
                  const SizedBox(height: 8),
                  Text('간이과세자·신규 사업자도 신청하실 수 있습니다.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: mutedText)),
                ],
                // 정산 계좌는 승인 후 셀러센터에서 등록한다 (신청 문턱을 낮추기 위해)
                if (_isEdit) ...[
                  const SizedBox(height: 24),
                  Text('정산 계좌',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text('첫 정산 전까지 등록하시면 됩니다.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: mutedText)),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _bankName,
                    decoration: const InputDecoration(labelText: '은행명'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _bankAccount,
                    decoration: const InputDecoration(
                        labelText: '계좌번호', hintText: '숫자만 입력 (- 제외)'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _accountHolder,
                    decoration: const InputDecoration(labelText: '예금주'),
                  ),
                ],
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_isEdit ? '수정 저장' : '입점 신청하기'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
