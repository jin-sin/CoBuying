import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cobuying/features/broadcast_orders/broadcast_purchase_export.dart';

void main() {
  test('거래처 XLSX에는 수량과 상품만 있고 고객 정보는 없다', () {
    final rows = [
      {
        'supplier': '거래처 A',
        'product_title': '데님조끼',
        'color': '검정',
        'size': 'M',
        'quantity': 5,
        'latest_received_quantity': 2,
        'cumulative_received_quantity': 3,
        'remaining_missing_quantity': 2,
        'defect_exchange_quantity': 1,
        'nickname': '외부에 노출되면 안 되는 고객',
        'note': '개인 메모',
      },
    ];
    final bytes = buildBroadcastPurchaseXlsx(
      rows,
      BroadcastPurchaseExportKind.supplier,
    );
    final excel = Excel.decodeBytes(bytes);
    final sheet = excel['거래처 발주표'];
    expect(sheet.cell(CellIndex.indexByString('A2')).value.toString(), '거래처 A');
    expect(sheet.cell(CellIndex.indexByString('B2')).value.toString(), '데님조끼');
    expect(
      (sheet.cell(CellIndex.indexByString('E2')).value as IntCellValue).value,
      5,
    );
    expect(
      (sheet.cell(CellIndex.indexByString('F2')).value as IntCellValue).value,
      2,
    );
    expect(
      (sheet.cell(CellIndex.indexByString('G2')).value as IntCellValue).value,
      3,
    );
    expect(
      (sheet.cell(CellIndex.indexByString('H2')).value as IntCellValue).value,
      2,
    );
    expect(
      (sheet.cell(CellIndex.indexByString('I2')).value as IntCellValue).value,
      1,
    );
    expect(sheet.maxColumns, 10);
    expect(sheet.cell(CellIndex.indexByString('J2')).value.toString(), '');
    expect(bytes.length, greaterThan(500));
  });

  test('내부 고객관리 XLSX는 같은 데이터에서 주문자와 메모를 보존한다', () {
    final rows = [
      {
        'product_title': '데님조끼',
        'color': '검정',
        'size': 'M',
        'quantity': 2,
        'nickname': '몽이맘',
        'payment_confirmed': true,
        'status': 'ordered',
        'note': '사이즈 확인',
      },
    ];
    final bytes = buildBroadcastPurchaseXlsx(
      rows,
      BroadcastPurchaseExportKind.customers,
    );
    final sheet = Excel.decodeBytes(bytes)['고객관리표'];
    expect(
      (sheet.cell(CellIndex.indexByString('D2')).value as IntCellValue).value,
      2,
    );
    expect(sheet.cell(CellIndex.indexByString('E2')).value.toString(), '몽이맘');
    expect(sheet.cell(CellIndex.indexByString('F2')).value.toString(), '확인');
    expect(
      sheet.cell(CellIndex.indexByString('H2')).value.toString(),
      '사이즈 확인',
    );
  });
}
