import 'dart:typed_data';

import 'package:excel/excel.dart';

enum BroadcastPurchaseExportKind { supplier, customers }

/// Two deliberately separate workbooks: supplier data never receives customer rows.
Uint8List buildBroadcastPurchaseXlsx(
  List<Map<String, dynamic>> rows,
  BroadcastPurchaseExportKind kind,
) {
  final excel = Excel.createExcel();
  final sheetName = kind == BroadcastPurchaseExportKind.supplier
      ? '거래처 발주표'
      : '고객관리표';
  excel.rename('Sheet1', sheetName);
  final sheet = excel[sheetName];
  final supplier = kind == BroadcastPurchaseExportKind.supplier;
  final headers = supplier
      ? [
          '거래처',
          '제품명',
          '컬러',
          '사이즈',
          '발주수량',
          '이번 입고수량',
          '누적 입고수량',
          '남은 미송수량',
          '불량교환 대기수량',
          '메모',
        ]
      : ['제품명', '컬러', '사이즈', '수량', '주문자', '입금확인', '현재상태', '메모'];
  sheet.appendRow(headers.map((v) => TextCellValue(v)).toList());
  for (final row in rows) {
    final cells = supplier
        ? [
            row['supplier'],
            row['product_title'],
            row['color'],
            row['size'],
            row['quantity'],
            row['latest_received_quantity'],
            row['cumulative_received_quantity'],
            row['remaining_missing_quantity'],
            row['defect_exchange_quantity'],
            '', // Supplier memo is blank until a separate supplier-only field exists.
          ]
        : [
            row['product_title'],
            row['color'],
            row['size'],
            row['quantity'],
            row['nickname'],
            row['payment_confirmed'] == true ? '확인' : '미확인',
            row['status'],
            row['note'],
          ];
    sheet.appendRow(cells.map(_cell).toList());
  }
  for (var i = 0; i < headers.length; i++) {
    sheet.setColumnWidth(i, i == 1 ? 28 : 18);
  }
  final bytes = excel.encode();
  if (bytes == null || bytes.isEmpty) {
    throw StateError('발주표 파일을 만들지 못했습니다.');
  }
  return Uint8List.fromList(bytes);
}

CellValue _cell(dynamic value) {
  if (value is int) return IntCellValue(value);
  // TextCellValue is not a formula, even for user-supplied names/notes.
  return TextCellValue(value?.toString() ?? '');
}
