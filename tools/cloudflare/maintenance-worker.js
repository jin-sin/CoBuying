/**
 * 점검 시간(break time) 안내 Worker.
 *
 * NAS 전원 스케줄(02~08시 KST) 등으로 원본 서버가 꺼져 있을 때
 * 방문자에게 에러 대신 점검 안내 페이지를 보여준다.
 *
 * 시간을 하드코딩하지 않고 "원본 응답 실패"를 감지하는 방식이라
 * 예정에 없던 장애 때도 동일하게 동작한다.
 * 라우트: shop.orange-man.xyz/*, photo.orange-man.xyz/* (wrangler.toml)
 */

// Cloudflare가 원본 접속 실패 시 돌려주는 상태 코드들
const ORIGIN_DOWN = new Set([521, 522, 523, 525, 526]);

export default {
  async fetch(request) {
    try {
      const resp = await fetch(request);
      if (ORIGIN_DOWN.has(resp.status)) {
        return maintenancePage(request);
      }
      return resp;
    } catch {
      return maintenancePage(request);
    }
  },
};

function maintenancePage(request) {
  const host = new URL(request.url).hostname;
  const isPhoto = host.startsWith('photo.');
  const html = isPhoto ? PHOTO_HTML : SHOP_HTML;
  return new Response(html, {
    status: 503,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      // 아침 8시 재개 — 브라우저/크롤러에게 재시도 힌트
      'retry-after': '3600',
      'cache-control': 'no-store',
    },
  });
}

const SHOP_HTML = `<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>오렌지맨 · 점검 시간</title>
<style>
  body { margin:0; font-family:-apple-system,'Apple SD Gothic Neo','Noto Sans KR',sans-serif;
         background:#fdf6f0; color:#3e2723; display:flex; align-items:center;
         justify-content:center; min-height:100vh; text-align:center; }
  .card { padding:40px 32px; max-width:420px; }
  .moon { font-size:64px; }
  h1 { font-size:22px; margin:20px 0 12px; }
  p { color:#795548; line-height:1.7; margin:0; white-space:pre-line; }
  .time { margin-top:20px; display:inline-block; background:#fbe9e7; color:#bf360c;
          border-radius:999px; padding:8px 18px; font-weight:600; font-size:14px; }
</style>
</head>
<body>
<div class="card">
  <div class="moon">🌙</div>
  <h1>break time ~</h1>
  <p>지금은 서버 점검 시간이에요.
아침에 다시 만나요!</p>
  <div class="time">매일 02:00 – 08:00 점검</div>
</div>
</body>
</html>`;

const PHOTO_HTML = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>乐梦童装 · 服务器维护中</title>
<style>
  body { margin:0; font-family:-apple-system,'PingFang SC','Noto Sans SC','Apple SD Gothic Neo',sans-serif;
         background:#0f1115; color:#f5f7fb; display:flex; align-items:center;
         justify-content:center; min-height:100vh; text-align:center; }
  .card { padding:40px 32px; max-width:420px; }
  .moon { font-size:64px; }
  h1 { font-size:22px; margin:20px 0 12px; }
  p { color:#a9b1c3; line-height:1.7; margin:0; }
  .time { margin-top:20px; display:inline-block; background:#171a21; border:1px solid #2a3040;
          border-radius:999px; padding:8px 18px; font-weight:600; font-size:14px; color:#ffd08a; }
</style>
</head>
<body>
<div class="card">
  <div class="moon">🌙</div>
  <h1>服务器维护中</h1>
  <p>现在是服务器例行维护时间，<br>请稍后再访问。早上见！</p>
  <div class="time">每天 02:00 – 08:00 (韩国时间)</div>
</div>
</body>
</html>`;
