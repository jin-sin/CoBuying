// 운영 장애 모니터 — Cloudflare Cron Trigger가 5분마다 실행한다.
//
// NAS가 죽으면 DB도 같이 죽어서 DB로는 그 사실을 알릴 수 없다. 그래서 판정은
// 전부 바깥(이 Worker)에서 하고, DB는 바깥에서 볼 수 없는 신호만 넘겨준다
// (schema.sql 27절 health_check).
//
// 상태가 바뀔 때만 알린다. 5분마다 같은 문구를 보내면 결국 안 보게 되기 때문에,
// 이상 → 정상 / 정상 → 이상 전환에서만 텔레그램을 울린다. 상태는 KV에 둔다.

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
  const planned = inWindow(now, env.WINDOW_START, env.WINDOW_END);
  const checks = [];

  // 점검창 안에서는 서버가 꺼져 있는 게 정상이라 아무것도 보지 않는다
  if (planned) return { planned, checks };

  const supa = await probe(`${env.SUPABASE_URL}/rest/v1/`, [200, 401]);
  checks.push({ key: 'supabase', label: 'Supabase', ...supa });

  const web = await probe(env.WEB_URL, [200]);
  checks.push({ key: 'web', label: '서비스 웹', ...web });

  // Supabase가 죽었으면 아래 항목은 전부 같이 실패한다. 알림을 도배하지 않도록
  // 원인 하나만 남기고 나머지는 건너뛴다.
  if (!supa.ok) return { planned, checks };

  const h = await health(env);
  checks.push({ key: 'health_rpc', label: '헬스체크 RPC', ok: h.ok, detail: h.detail });
  if (!h.ok) return { planned, checks };

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

  return { planned, checks };
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

const fmtDuration = (ms) => {
  const m = Math.round(ms / 60000);
  return m < 60 ? `${m}분` : `${Math.floor(m / 60)}시간 ${m % 60}분`;
};

async function tick(env, now) {
  const { planned, checks } = await runChecks(env, now);
  if (planned) return { skipped: '점검 시간' };

  const prev = JSON.parse((await env.MONITOR_STATE.get('state')) ?? '{}');
  const next = {};
  const down = [];
  const up = [];

  for (const c of checks) {
    const was = prev[c.key];
    next[c.key] = { ok: c.ok, since: was && was.ok === c.ok ? was.since : now.getTime() };
    if (was && was.ok === c.ok) continue; // 상태 그대로 — 알리지 않는다
    (c.ok ? up : down).push({ ...c, since: was?.since });
  }

  // 이번에 확인하지 못한 항목(선행 실패로 건너뛴 것)은 이전 상태를 유지한다.
  // 지워버리면 복구됐다고 잘못 판단한다.
  for (const [k, v] of Object.entries(prev)) if (!(k in next)) next[k] = v;

  await env.MONITOR_STATE.put('state', JSON.stringify(next));

  const quiet = inWindow(now, env.QUIET_START, env.QUIET_END);
  const lines = [];
  for (const c of down) lines.push(`🔴 ${c.label} 이상${c.detail ? ` — ${c.detail}` : ''}`);
  for (const c of up) {
    const dur = c.since ? ` (${fmtDuration(now.getTime() - c.since)} 만에)` : '';
    lines.push(`🟢 ${c.label} 정상 복구${dur}`);
  }
  if (lines.length) {
    await notify(env, `[오렌지맨]\n${lines.join('\n')}`, quiet);
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
    const { planned, checks } = await runChecks(env, now);
    return Response.json({ kst: kstMinutes(now), planned, checks });
  },
};
