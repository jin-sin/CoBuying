import 'package:cobuying/features/broadcast_orders/broadcast_purchase_export.dart';
import 'package:excel/excel.dart';

void main() {
  final supplier = buildBroadcastPurchaseXlsx([
    {
      'supplier': '도매상',
      'product_title': '조끼',
      'color': '검정',
      'size': 'M',
      'quantity': 5,
      'latest_received_quantity': 2,
      'cumulative_received_quantity': 3,
      'remaining_missing_quantity': 2,
      'defect_exchange_quantity': 1,
      'nickname': '고객 비공개',
      'note': '고객 개인 메모',
    },
  ], BroadcastPurchaseExportKind.supplier);
  final sheet = Excel.decodeBytes(supplier)['거래처 발주표'];
  assert(sheet.maxColumns == 10);
  assert(
    (sheet.cell(CellIndex.indexByString('E2')).value as IntCellValue).value ==
        5,
  );
  assert(sheet.cell(CellIndex.indexByString('A2')).value.toString() == '도매상');
  assert((sheet.cell(CellIndex.indexByString('F2')).value as IntCellValue).value == 2);
  assert(sheet.cell(CellIndex.indexByString('J2')).value.toString() == '');
  final internal = buildBroadcastPurchaseXlsx([
    {
      'product_title': '조끼',
      'color': '검정',
      'size': 'M',
      'quantity': 1,
      'nickname': '몽이맘',
      'payment_confirmed': true,
      'status': 'ordered',
      'note': '확인',
    },
  ], BroadcastPurchaseExportKind.customers);
  final internalSheet = Excel.decodeBytes(internal)['고객관리표'];
  assert(
    internalSheet.cell(CellIndex.indexByString('E2')).value.toString() == '몽이맘',
  );
  print('발주표/고객관리표 XLSX 생성·재읽기 통과');
}
