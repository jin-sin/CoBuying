/// 택배사 목록과 배송조회 URL.
/// 목록에 없는 택배사(기타 등)는 네이버 검색으로 연결한다.
const courierNames = [
  'CJ대한통운',
  '우체국택배',
  '한진택배',
  '롯데택배',
  '로젠택배',
  '기타',
];

Uri courierTrackingUrl(String courier, String trackingNumber) {
  final n = Uri.encodeComponent(trackingNumber);
  return switch (courier) {
    'CJ대한통운' =>
      Uri.parse('https://trace.cjlogistics.com/next/tracking.html?wblNo=$n'),
    '우체국택배' => Uri.parse(
        'https://service.epost.go.kr/trace.RetrieveDomRigiTraceList.comm?sid1=$n'),
    '한진택배' => Uri.parse(
        'https://www.hanjin.com/kor/CMS/DeliveryMgr/WaybillResult.do?mCode=MN038&schLang=KR&wblnumText2=$n'),
    '롯데택배' => Uri.parse(
        'https://www.lotteglogis.com/home/reservation/tracking/linkView?InvNo=$n'),
    '로젠택배' =>
      Uri.parse('https://www.ilogen.com/web/personal/trace/$n'),
    _ => Uri.parse('https://search.naver.com/search.naver?query='
        '${Uri.encodeComponent('$courier $trackingNumber')}'),
  };
}
