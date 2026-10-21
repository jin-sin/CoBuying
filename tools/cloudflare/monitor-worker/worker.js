// 운영 장애 모니터 — Cloudflare Cron Trigger가 5분마다 실행한다.
//
// NAS가 죽으면 DB도 같이 죽어서 DB로는 그 사실을 알릴 수 없다. 그래서 판정은
// 전부 바깥(이 Worker)에서 하고, DB는 바깥에서 볼 수 없는 신호만 넘겨준다
// (schema.sql 27절 health_check).
//
// 상태가 바뀔 때만 알린다. 5분마다 같은 문구를 보내면 결국 안 보게 되기 때문에,
// 이상 → 정상 / 정상 → 이상 전환에서만 텔레그램을 울린다. 상태는 KV에 둔다.
//
// 단, **한 번 실패했다고 바로 알리지는 않는다.** 집에 있는 NAS로 가는 길
// (Cloudflare → 가정 회선 → DSM 역방향 프록시)은 서버가 멀쩡해도 가끔 한 번씩
// 끊긴다. 그때마다 폰이 울리면 정작 진짜 장애 때 안 보게 된다. 그래서 두 단으로
// 거른다 — tick 안에서 한 번 더 해보고(PROBE_TRIES), 그래도 실패하면 다음
// tick까지 기다려 연속 FAIL_THRESHOLD번이 되어야 '이상'으로 확정한다.
// (2026-08-14 16:40~16:45 웹·Supabase 오탐이 이 경우였다. 서버 로그에는
//  아무 흔적이 없었다 — 요청이 NAS까지 오지도 못했다.)

const KST_OFFSET_MIN = 9 * 60;

const parseHm = (s) => {
  const [h, m] = s.split(':').map(Number);
  return h * 60 + m;
};

const kstMinutes = (now) =>
  (now.getUTCHours() * 60 + now.getUTCMinutes() + KST_OFFSET_MIN) % 1440;

// 자정을 넘는 구간(23:00~08:00)도 지원한다
function inWindow(now, startHm, endHm) {
  const t = kstMinutes(now);
  const s = parseHm(startHm);
  const e = parseHm(endHm);
  return s <= e ? t >= s && t < e : t >= s || t < e;
}

const minutesSince = (now, hm) => (kstMinutes(now) - parseHm(hm) + 1440) % 1440;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 순간적인 패킷 유실은 여기서 걸러진다. 몇 분짜리 끊김은 이걸로 못 잡으니
// 연속 실패 판정(decide)이 맡는다 — 둘은 거르는 길이가 다르다.
async function attempt(fn, tries, gapMs) {
  let last;
  for (let i = 0; i < tries; i++) {
    if (i) await sleep(gapMs);
    last = await fn();
    if (last.ok) return last;
  }
  return last;
}

async function probe(url, accept) {
  try {
    const resp = await fetch(url, {
      method: 'GET',
      cf: { cacheTtl: 0 },
      signal: AbortSignal.timeout(10000),
    });
    return accept.includes(resp.status)
      ? { ok: true }
      : { ok: false, detail: `HTTP ${resp.status}` };
  } catch (e) {
    return { ok: false, detail: String(e).slice(0, 120) };
  }
}

async function health(env) {
  try {
    const resp = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/health_check`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        apikey: env.SUPABASE_ANON_KEY,
        authorization: `Bearer ${env.SUPABASE_ANON_KEY}`,
      },
      body: JSON.stringify({ p_token: env.HEALTH_TOKEN }),
      signal: AbortSignal.timeout(10000),
    });
    if (resp.status !== 200) {
      return { ok: false, detail: `health_check HTTP ${resp.status}` };
    }
    return { ok: true, data: await resp.json() };
  } catch (e) {
    return { ok: false, detail: String(e).slice(0, 120) };
  }
}

// 하루 한 번 도는 작업은 '마지막 성공이 너무 오래됐다'로 실패를 잡는다.
// 스크립트가 실패한 경우와 아예 안 돈 경우가 같이 걸린다 (데드맨 스위치).
function heartbeatCheck(data, name, label, maxAgeSec) {
  const age = data.heartbeat_age?.[name];
  if (age === undefined) {
    return { ok: false, detail: `${label}: 기록 없음 (한 번도 실행 안 됨)` };
  }
  return age > maxAgeSec
    ? { ok: false, detail: `${label}: 마지막 성공 ${Math.round(age / 3600)}시간 전` }
    : { ok: true };
}

async function runChecks(env, now) {
  const checks = [];

  // 점검창 안에서는 서버가 꺼져 있는 게 정상이라 아무것도 보지 않는다
  if (inWindow(now, env.WINDOW_START, env.WINDOW_END)) {
    return { skip: '점검 시간', checks };
  }

  // WINDOW_END는 NAS에 "전원이 들어오는" 시각이지 서비스가 뜨는 시각이 아니다.
  // 부팅에 4~5분 걸려서 창이 끝나자마자 확인하면 멀쩡한 아침을 장애로 잡는다.
  if (minutesSince(now, env.WINDOW_END) < Number(env.BOOT_GRACE_MIN)) {
    return { skip: '부팅 유예', checks };
  }

  const tries = Number(env.PROBE_TRIES ?? 2);
  const gap = Number(env.PROBE_GAP_MS ?? 2000);

  const supa = await attempt(
    () => probe(`${env.SUPABASE_URL}/rest/v1/`, [200, 401]), tries, gap);
  checks.push({ key: 'supabase', label: 'Supabase', ...supa });

  const web = await attempt(() => probe(env.WEB_URL, [200]), tries, gap);
  checks.push({ key: 'web', label: '서비스 웹', ...web });

  // Supabase가 죽었으면 아래 항목은 전부 같이 실패한다. 알림을 도배하지 않도록
  // 원인 하나만 남기고 나머지는 건너뛴다.
  if (!supa.ok) return { checks };

  const h = await attempt(() => health(env), tries, gap);
  checks.push({ key: 'health_rpc', label: '헬스체크 RPC', ok: h.ok, detail: h.detail });
  if (!h.ok) return { checks };

  const d = h.data;
  checks.push({
    key: 'db_backup',
    label: 'DB 백업',
    ...heartbeatCheck(d, 'db_backup', 'DB 백업', Number(env.BACKUP_MAX_AGE_SEC)),
  });
  checks.push({
    key: 'offsite_backup',
    label: '오프사이트 백업',
    ...heartbeatCheck(d, 'offsite_backup', '오프사이트 백업', Number(env.BACKUP_MAX_AGE_SEC)),
  });

  // pg_cron은 점검창 동안 서버와 함께 멈춘다. 기상 직후에는 마지막 성공이
  // 6시간 전이라 정상인데도 실패로 잡히므로, 창이 끝나고 얼마간은 건너뛴다.
  if (minutesSince(now, env.WINDOW_END) > Number(env.CRON_GRACE_MIN)) {
    const stale = Object.entries(d.cron_age ?? {})
      .filter(([, age]) => age === null || age > Number(env.CRON_MAX_AGE_SEC))
      .map(([job]) => job);
    checks.push({
      key: 'pg_cron',
      label: 'pg_cron',
      ok: stale.length === 0,
      detail: stale.length ? `멈춘 잡: ${stale.join(', ')}` : undefined,
    });
  }

  const oldest = Number(d.push_oldest_sec ?? 0);
  checks.push({
    key: 'push_queue',
    label: '푸시 큐',
    ok: oldest <= Number(env.PUSH_MAX_AGE_SEC),
    detail: `${d.push_pending}건 적체, 가장 오래된 것 ${Math.round(oldest / 60)}분`,
  });

  return { checks };
}

async function notify(env, text, quiet) {
  if (!env.TELEGRAM_TOKEN || !env.TELEGRAM_CHAT_ID) {
    console.log('텔레그램 미설정 — 알림 생략:', text);
    return;
  }
  const resp = await fetch(
    `https://api.telegram.org/bot${env.TELEGRAM_TOKEN}/sendMessage`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        chat_id: env.TELEGRAM_CHAT_ID,
        text,
        disable_notification: quiet,
      }),
    },
  );
  if (!resp.ok) console.log('텔레그램 전송 실패:', resp.status, await resp.text());
}

// 크론은 Cloudflare가 고른 콜로에서 돈다 — 우리가 지정할 수 없다. 어느
// 콜로였는지 남겨두면 '해외 콜로일 때만 막힌다'를 추측이 아니라 기록으로
// 확인할 수 있다. 원본 방화벽의 지역 제한을 의심할 때 이 한 줄이 결론을 낸다.
async function colo() {
  try {
    const r = await fetch('https://cloudflare.com/cdn-cgi/trace', {
      signal: AbortSignal.timeout(5000),
    });
    return (await r.text()).match(/^colo=(\w+)/m)?.[1] ?? '?';
  } catch {
    return '?';
  }
}

const fmtDuration = (ms) => {
  const m = Math.round(ms / 60000);
  return m < 60 ? `${m}분` : `${Math.floor(m / 60)}시간 ${m % 60}분`;
};

// 확정 상태 전환 판정. 알림을 보낼지 말지가 전부 여기서 갈려서 순수 함수로
// 떼어 두고 테스트한다.
//
// 항목마다 KV에 { ok, since, fails, firstFail }을 둔다. `ok`는 **확정** 상태고
// (= 마지막으로 알린 상태), `fails`는 아직 확정 안 된 연속 실패 횟수다.
// 이상으로 확정할 때 `since`를 첫 실패 시각으로 되돌려서, 나중에 복구 알림의
// 지속 시간이 확정 시점이 아니라 실제로 끊긴 시점부터 계산되게 한다.
export function decide(prev, checks, nowMs, threshold) {
  // 이번에 확인하지 못한 항목(선행 실패로 건너뛴 것)은 이전 상태를 유지한다.
  // 지워버리면 복구됐다고 잘못 판단한다.
  const next = { ...prev };
  const down = [];
  const up = [];

  for (const c of checks) {
    // 처음 보는 항목은 정상으로 친다 — 첫 배포에 🟢을 도배하지 않게
    const was = prev[c.key] ?? { ok: true, since: nowMs };

    if (c.ok) {
      next[c.key] = { ok: true, since: was.ok ? was.since : nowMs, fails: 0 };
      if (!was.ok) up.push({ ...c, since: was.since });
      continue;
    }

    const fails = (was.fails ?? 0) + 1;
    if (was.ok && fails < threshold) {
      // 아직 확정 아님 — 횟수만 세고 조용히 넘어간다
      next[c.key] = { ...was, fails, firstFail: was.firstFail ?? nowMs };
      continue;
    }
    next[c.key] = {
      ok: false,
      since: was.ok ? (was.firstFail ?? nowMs) : was.since,
      fails,
    };
    if (was.ok) down.push(c);
  }

  return { next, down, up };
}

async function tick(env, now) {
  const { skip, checks } = await runChecks(env, now);
  if (skip) return { skipped: skip };

  console.log(JSON.stringify({
    colo: await colo(),
    checks: checks.map((c) => ({ k: c.key, ok: c.ok, d: c.detail })),
  }));

  const prev = JSON.parse((await env.MONITOR_STATE.get('state')) ?? '{}');
  const { next, down, up } = decide(
    prev, checks, now.getTime(), Number(env.FAIL_THRESHOLD ?? 2));

  await env.MONITOR_STATE.put('state', JSON.stringify(next));

  const quiet = inWindow(now, env.QUIET_START, env.QUIET_END);
  const lines = [];
  for (const c of down) lines.push(`🔴 ${c.label} 이상${c.detail ? ` — ${c.detail}` : ''}`);
  for (const c of up) {
    const dur = c.since ? ` (${fmtDuration(now.getTime() - c.since)} 만에)` : '';
    lines.push(`🟢 ${c.label} 정상 복구${dur}`);
  }
  if (lines.length) {
    await notify(env, `[오렌담마켓]\n${lines.join('\n')}`, quiet);
  }

  return { checked: checks.length, changed: lines.length, quiet };
}

// 시간대 판정은 자정을 넘는 구간 때문에 틀리기 쉬워 테스트에서 직접 부른다
export { inWindow, kstMinutes, minutesSince, heartbeatCheck };

export default {
  async scheduled(_event, env, ctx) {
    ctx.waitUntil(tick(env, new Date()));
  },

  // 설정 확인용 — 크론을 기다리지 않고 지금 상태를 볼 때 쓴다.
  // curl -H "Authorization: Bearer <HEALTH_TOKEN>" https://<worker>/check
  async fetch(request, env) {
    if (request.headers.get('authorization') !== `Bearer ${env.HEALTH_TOKEN}`) {
      return new Response('unauthorized', { status: 401 });
    }
    const now = new Date();
    const { skip, checks } = await runChecks(env, now);
    // 확정 상태와 미확정 연속 실패 횟수도 같이 보여준다 — 실패가 쌓이는
    // 중인지(알림 전) 이미 알린 뒤인지가 여기서만 구분된다.
    const state = JSON.parse((await env.MONITOR_STATE.get('state')) ?? '{}');
    return Response.json({ kst: kstMinutes(now), skip: skip ?? null, checks, state });
  },
};
