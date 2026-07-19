// CoBuying FCM 푸시 발송 Worker
//
// DB의 send_push_notifications()(pg_cron, 1분 주기)가 알림 배치를
// POST로 보내면, Firebase 서비스 계정으로 OAuth 토큰을 발급받아
// FCM v1 API로 기기에 푸시한다. FCM이 무효라고 응답한 토큰 목록을
// 돌려줘서 DB가 push_tokens에서 지우게 한다.
//
// 시크릿 (wrangler secret put):
//   FIREBASE_SERVICE_ACCOUNT  Firebase 콘솔에서 받은 서비스 계정 JSON 통째
//   PUSH_SHARED_SECRET        DB private.app_secrets의 push_shared_secret과 동일 값
//
// 요청:  POST /  Authorization: Bearer <PUSH_SHARED_SECRET>
//        { "messages": [ { "token", "title", "body", "link" }, ... ] }
// 응답:  { "sent": n, "failed": n, "invalid": ["<무효 토큰>", ...] }

// OAuth 액세스 토큰 캐시 (Worker 인스턴스가 살아있는 동안 재사용)
let cachedToken = null; // { token, exp }

function b64url(bytes) {
  let bin = '';
  for (const b of new Uint8Array(bytes)) bin += String.fromCharCode(b);
  return btoa(bin).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}

function pemToBuffer(pem) {
  const b64 = pem.replace(/-----[A-Z ]+-----/g, '').replace(/\s/g, '');
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

async function getAccessToken(sa) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now < cachedToken.exp - 60) return cachedToken.token;

  const enc = new TextEncoder();
  const header = b64url(enc.encode(JSON.stringify({ alg: 'RS256', typ: 'JWT' })));
  const claims = b64url(enc.encode(JSON.stringify({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  })));
  const unsigned = `${header}.${claims}`;

  const key = await crypto.subtle.importKey(
    'pkcs8', pemToBuffer(sa.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5', key, enc.encode(unsigned));
  const jwt = `${unsigned}.${b64url(sig)}`;

  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer'
      + `&assertion=${jwt}`,
  });
  if (!resp.ok) throw new Error(`OAuth 토큰 발급 실패: HTTP ${resp.status}`);
  const json = await resp.json();
  cachedToken = { token: json.access_token, exp: now + (json.expires_in ?? 3600) };
  return cachedToken.token;
}

async function sendOne(projectId, accessToken, msg, env) {
  const body = {
    message: {
      token: msg.token,
      notification: { title: msg.title, body: msg.body },
      data: { link: msg.link ?? '' },
      android: { priority: 'high' },
      webpush: msg.link
        // Flutter 웹은 해시 라우팅 — 클릭 시 이동할 절대 URL로 변환
        ? { fcm_options: { link: `${env.WEB_LINK_BASE}/#${msg.link}` } }
        : undefined,
    },
  };

  const resp = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: 'POST',
      headers: {
        authorization: `Bearer ${accessToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify(body),
    });

  if (resp.ok) return 'sent';

  const err = await resp.json().catch(() => ({}));
  const fcmCode = err?.error?.details
    ?.find((d) => d['@type']?.includes('FcmError'))?.errorCode;
  // 앱 삭제·토큰 만료(UNREGISTERED) 또는 형식이 깨진 토큰 → DB에서 제거 대상
  if (resp.status === 404 || fcmCode === 'UNREGISTERED'
      || fcmCode === 'INVALID_ARGUMENT') {
    return 'invalid';
  }
  console.log(`FCM 발송 실패 HTTP ${resp.status}: ${JSON.stringify(err?.error?.message ?? err)}`);
  return 'failed';
}

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }
    const auth = request.headers.get('authorization') ?? '';
    if (!env.PUSH_SHARED_SECRET || auth !== `Bearer ${env.PUSH_SHARED_SECRET}`) {
      return new Response('unauthorized', { status: 401 });
    }

    let messages;
    try {
      ({ messages } = await request.json());
      if (!Array.isArray(messages)) throw new Error('messages 배열이 없음');
    } catch (e) {
      return Response.json({ error: String(e) }, { status: 400 });
    }

    const sa = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
    const accessToken = await getAccessToken(sa);

    const invalid = [];
    let sent = 0;
    let failed = 0;
    const results = await Promise.allSettled(
      messages.map((m) => sendOne(sa.project_id, accessToken, m, env)));
    results.forEach((r, i) => {
      if (r.status !== 'fulfilled') failed += 1;
      else if (r.value === 'sent') sent += 1;
      else if (r.value === 'invalid') invalid.push(messages[i].token);
      else failed += 1;
    });

    return Response.json({ sent, failed, invalid });
  },
};
