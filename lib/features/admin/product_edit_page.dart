import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/formatters.dart';
import '../products/product.dart';
import '../products/products_providers.dart';

/// 상품 등록/수정 페이지. [productId]가 null이면 신규 등록.
class ProductEditPage extends ConsumerStatefulWidget {
  const ProductEditPage({super.key, this.productId});

  final String? productId;

  @override
  ConsumerState<ProductEditPage> createState() => _ProductEditPageState();
}

class _ProductEditPageState extends ConsumerState<ProductEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _price = TextEditingController();
  final _originalPrice = TextEditingController();
  final _stock = TextEditingController();

  DateTime _startsAt = DateTime.now();
  DateTime _endsAt = DateTime.now().add(const Duration(days: 1));
  List<String> _imageUrls = [];
  final List<_OptionGroupEdit> _optionGroups = [];
  bool _loading = false;
  bool _saving = false;
  bool _uploadingImage = false;

  bool get _isEdit => widget.productId != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) _loadProduct();
  }

  Future<void> _loadProduct() async {
    setState(() => _loading = true);
    final product = await ref
        .read(productsRepositoryProvider)
        .fetchProduct(widget.productId!);
    if (product != null && mounted) {
      _title.text = product.title;
      _description.text = product.description;
      _price.text = '${product.price}';
      _originalPrice.text =
          product.originalPrice == null ? '' : '${product.originalPrice}';
      _stock.text = '${product.stock}';
      setState(() {
        _startsAt = product.startsAt.toLocal();
        _endsAt = product.endsAt.toLocal();
        _imageUrls = [...product.imageUrls];
        _optionGroups
          ..clear()
          ..addAll(product.options.map(_OptionGroupEdit.from));
      });
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    for (final c in [_title, _description, _price, _originalPrice, _stock]) {
      c.dispose();
    }
    for (final g in _optionGroups) {
      g.name.dispose();
    }
    super.dispose();
  }

  /// 옵션 그룹 편집 상태 → 저장용 모델. 이름/선택지가 비면 예외 메시지.
  List<ProductOption> _buildOptions() {
    final result = <ProductOption>[];
    for (final g in _optionGroups) {
      final name = g.name.text.trim();
      if (name.isEmpty) {
        throw '옵션 그룹 이름을 입력하세요.';
      }
      if (g.choices.isEmpty) {
        throw '옵션 "$name"에 선택지를 하나 이상 추가하세요.';
      }
      result.add(ProductOption(name: name, choices: [...g.choices]));
    }
    return result;
  }

  Future<void> _addChoice(_OptionGroupEdit group) async {
    final choice = await showDialog<OptionChoice>(
      context: context,
      builder: (context) => const _ChoiceDialog(),
    );
    if (choice == null) return;
    setState(() {
      // 같은 이름 선택지는 교체 (추가금 수정 용도)
      group.choices.removeWhere((c) => c.name == choice.name);
      group.choices.add(choice);
    });
  }

  Future<void> _pickAndUploadImage() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, maxWidth: 1600);
    if (picked == null) return;

    setState(() => _uploadingImage = true);
    try {
      final bytes = await picked.readAsBytes();
      final url = await ref
          .read(productsRepositoryProvider)
          .uploadImage(picked.name, bytes);
      setState(() => _imageUrls.add(url));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('이미지 업로드 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  Future<void> _pickDateTime({required bool isEnd}) async {
    final initial = isEnd ? _endsAt : _startsAt;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return;
    final picked =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isEnd) {
        _endsAt = picked;
      } else {
        _startsAt = picked;
      }
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_endsAt.isAfter(_startsAt)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('판매 마감이 시작보다 빠를 수 없습니다.')));
      return;
    }

    final List<ProductOption> options;
    try {
      options = _buildOptions();
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
      return;
    }

    final product = Product(
      id: widget.productId ?? '',
      options: options,
      title: _title.text.trim(),
      description: _description.text.trim(),
      price: int.parse(_price.text.trim()),
      originalPrice: _originalPrice.text.trim().isEmpty
          ? null
          : int.parse(_originalPrice.text.trim()),
      stock: int.parse(_stock.text.trim()),
      imageUrls: _imageUrls,
      startsAt: _startsAt,
      endsAt: _endsAt,
      status: 'active',
    );

    setState(() => _saving = true);
    try {
      final repo = ref.read(productsRepositoryProvider);
      if (_isEdit) {
        await repo.updateProduct(widget.productId!, product);
      } else {
        await repo.createProduct(product);
      }
      ref.invalidate(allProductsProvider);
      ref.invalidate(myProductsProvider);
      ref.invalidate(activeProductsProvider);
      if (!mounted) return;
      context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('저장에 실패했습니다: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _requiredNumber(String? v) {
    if (v == null || v.trim().isEmpty) return '필수 입력입니다';
    if (int.tryParse(v.trim()) == null) return '숫자만 입력하세요';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // 자주 쓰는 기한 프리셋 (시간 단위 포함)
    const presets = {
      '6시간': Duration(hours: 6),
      '12시간': Duration(hours: 12),
      '1일': Duration(days: 1),
      '2일': Duration(days: 2),
      '3일': Duration(days: 3),
      '7일': Duration(days: 7),
    };

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '상품 수정' : '상품 등록')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      TextFormField(
                        controller: _title,
                        decoration: const InputDecoration(labelText: '상품명 *'),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? '상품명을 입력하세요'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _description,
                        decoration: const InputDecoration(labelText: '상품 설명'),
                        maxLines: 5,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _price,
                              decoration: const InputDecoration(
                                  labelText: '공동구매가 (원) *'),
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              validator: _requiredNumber,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: _originalPrice,
                              decoration: const InputDecoration(
                                  labelText: '정가 (선택)'),
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _stock,
                        decoration: const InputDecoration(labelText: '재고 수량 *'),
                        keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                        validator: _requiredNumber,
                      ),
                      const SizedBox(height: 24),
                      Text('옵션 (선택)',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        '사이즈·색상·분쇄도처럼 구매자가 골라야 하는 항목. 선택지에 추가금(+원)도 넣을 수 있어요.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 8),
                      for (final group in _optionGroups)
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(12, 4, 12, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextFormField(
                                        controller: group.name,
                                        decoration: const InputDecoration(
                                          labelText: '옵션 이름 (예: 사이즈)',
                                          border: InputBorder.none,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline),
                                      tooltip: '옵션 삭제',
                                      onPressed: () => setState(() {
                                        group.name.dispose();
                                        _optionGroups.remove(group);
                                      }),
                                    ),
                                  ],
                                ),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    for (final c in group.choices)
                                      InputChip(
                                        label: Text(c.extra > 0
                                            ? '${c.name} (+${formatWon(c.extra)})'
                                            : c.name),
                                        onDeleted: () => setState(
                                            () => group.choices.remove(c)),
                                      ),
                                    ActionChip(
                                      avatar: const Icon(Icons.add, size: 18),
                                      label: const Text('선택지'),
                                      onPressed: () => _addChoice(group),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('옵션 그룹 추가'),
                        onPressed: () => setState(
                            () => _optionGroups.add(_OptionGroupEdit())),
                      ),
                      const SizedBox(height: 24),
                      Text('판매 기간',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('판매 시작'),
                        subtitle: const Text('날짜와 시간(분 단위)까지 선택됩니다'),
                        trailing: TextButton.icon(
                          icon: const Icon(Icons.edit_calendar_outlined),
                          onPressed: () => _pickDateTime(isEnd: false),
                          label: Text(formatDateTime(_startsAt)),
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('판매 마감'),
                        subtitle: const Text('날짜 선택 후 시간 선택 창이 이어서 뜹니다'),
                        trailing: TextButton.icon(
                          icon: const Icon(Icons.edit_calendar_outlined),
                          onPressed: () => _pickDateTime(isEnd: true),
                          label: Text(formatDateTime(_endsAt)),
                        ),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final entry in presets.entries)
                            ActionChip(
                              label: Text('시작 후 ${entry.key}'),
                              onPressed: () => setState(
                                  () => _endsAt = _startsAt.add(entry.value)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Text('상품 이미지',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < _imageUrls.length; i++)
                            Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(_imageUrls[i],
                                      width: 96, height: 96, fit: BoxFit.cover),
                                ),
                                Positioned(
                                  top: 0,
                                  right: 0,
                                  child: InkWell(
                                    onTap: () => setState(
                                        () => _imageUrls.removeAt(i)),
                                    child: Container(
                                      decoration: const BoxDecoration(
                                        color: Colors.black54,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.close,
                                          size: 18, color: Colors.white),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          InkWell(
                            onTap: _uploadingImage ? null : _pickAndUploadImage,
                            child: Container(
                              width: 96,
                              height: 96,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: _uploadingImage
                                  ? const Center(
                                      child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2)))
                                  : const Icon(Icons.add_a_photo_outlined),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : Text(_isEdit ? '수정 저장' : '상품 등록'),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

/// 옵션 그룹 편집 상태 (이름 컨트롤러 + 선택지 목록)
class _OptionGroupEdit {
  _OptionGroupEdit() : name = TextEditingController();

  _OptionGroupEdit.from(ProductOption option)
      : name = TextEditingController(text: option.name),
        choices = [...option.choices];

  final TextEditingController name;
  List<OptionChoice> choices = [];
}

/// 선택지 추가 다이얼로그 (이름 + 추가금)
class _ChoiceDialog extends StatefulWidget {
  const _ChoiceDialog();

  @override
  State<_ChoiceDialog> createState() => _ChoiceDialogState();
}

class _ChoiceDialogState extends State<_ChoiceDialog> {
  final _name = TextEditingController();
  final _extra = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _extra.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(
      context,
      OptionChoice(name: name, extra: int.tryParse(_extra.text.trim()) ?? 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('선택지 추가'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: '선택지 이름 (예: L)'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _extra,
            decoration: const InputDecoration(
                labelText: '추가금 (원, 없으면 비워두세요)'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(onPressed: _submit, child: const Text('추가')),
      ],
    );
  }
}
