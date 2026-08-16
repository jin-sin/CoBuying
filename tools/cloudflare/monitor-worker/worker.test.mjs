// 시간대 판정 테스트 — node tools/cloudflare/monitor-worker/worker.test.mjs
//
// 점검창(02:00~08:00)과 무음창(23:00~08:00)은 자정을 넘느냐 아니냐가 갈려서
// 부호 하나로 조용히 틀리기 쉽다. 틀리면 장애를 놓치거나 새벽에 폰이 울린다.
import { inWindow, kstMinutes, minutesSince, heartbeatCheck, decide } from './worker.js';

let fail = 0;
const eq = (label, got, want) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    fail++;
    console.log(`FAIL ${label}: got ${JSON.stringify(got)} want ${JSON.stringify(want)}`);
  } else {
    console.log(`ok   ${label}`);
  }
};

// Worker는 UTC로 돈다. KST = UTC+9
const at = (utcHm) => new Date(`2026-07-31T${utcHm}:00Z`);

eq('00:00 UTC = 09:00 KST', kstMinutes(at('00:00')), 9 * 60);
eq('17:00 UTC = 02:00 KST', kstMinutes(at('17:00')), 2 * 60);
eq('20:00 UTC = 05:00 KST (자정 넘김)', kstMinutes(at('20:00')), 5 * 60);

// 점검창 02:00~08:00 KST = 17:00~23:00 UTC
eq('점검창 시작 직후', inWindow(at('17:05'), '02:00', '08:00'), true);
eq('점검창 한가운데', inWindow(at('20:00'), '02:00', '08:00'), true);
eq('점검창 끝 직전', inWindow(at('22:55'), '02:00', '08:00'), true);
eq('점검창 끝나는 순간은 제외', inWindow(at('23:00'), '02:00', '08:00'), false);
eq('점검창 시작 직전', inWindow(at('16:55'), '02:00', '08:00'), false);
eq('한낮은 창 밖', inWindow(at('06:00'), '02:00', '08:00'), false);

// 무음창 23:00~08:00 KST — 자정을 넘는 구간
eq('무음창 자정 전', inWindow(at('14:30'), '23:00', '08:00'), true);
eq('무음창 자정 후', inWindow(at('20:00'), '23:00', '08:00'), true);
eq('무음창 밖', inWindow(at('05:00'), '23:00', '08:00'), false);

// 부팅/pg_cron 유예 판정용 — 창이 끝난 뒤 얼마나 지났나
eq('창 종료 5분 후', minutesSince(at('23:05'), '08:00'), 5);
eq('창 종료 3시간 후', minutesSince(at('02:00'), '08:00'), 180);
eq('창 종료 직전(거의 하루)', minutesSince(at('22:55'), '08:00'), 1435);

// 부팅 유예 15분 — 08:01 오탐(2026-08-04)이 걸러지는지
const booting = (utc) => minutesSince(at(utc), '08:00') < 15;
eq('08:01은 아직 부팅 중', booting('23:01'), true);
eq('08:14도 부팅 유예 안', booting('23:14'), true);
eq('08:15부터는 감시', booting('23:15'), false);
eq('한낮은 부팅 유예 아님', booting('06:00'), false);

eq('하트비트 신선',
   heartbeatCheck({ heartbeat_age: { db_backup: 3600 } }, 'db_backup', 'DB 백업', 93600),
   { ok: true });
eq('하트비트 없음 (한 번도 안 돎)',
   heartbeatCheck({ heartbeat_age: {} }, 'db_backup', 'DB 백업', 93600),
   { ok: false, detail: 'DB 백업: 기록 없음 (한 번도 실행 안 됨)' });
eq('하트비트 만료',
   heartbeatCheck({ heartbeat_age: { db_backup: 100000 } }, 'db_backup', 'DB 백업', 93600),
   { ok: false, detail: 'DB 백업: 마지막 성공 28시간 전' });

// ── 확정 판정 (오탐 거르기) ───────────────────────────────────
// 알림을 보낼지가 전부 여기서 갈린다. 한 번 삐끗한 걸로 폰이 울리면 안 되고,
// 진짜로 죽었는데 조용해도 안 된다.
const T = 2; // FAIL_THRESHOLD
const ok = (key) => [{ key, label: key, ok: true }];
const bad = (key, detail) => [{ key, label: key, ok: false, detail }];
const names = (a) => a.map((c) => c.key);

// 1회 실패는 확정하지 않는다 (8/14 오탐이 여기서 걸린다)
let s = decide({}, bad('web', 'TimeoutError'), 1000, T);
eq('1회 실패는 알리지 않음', [names(s.down), names(s.up)], [[], []]);
eq('1회 실패는 확정 상태 유지', [s.next.web.ok, s.next.web.fails], [true, 1]);

// 다음 tick에서 회복 — 조용히 지나가야 한다
let r = decide(s.next, ok('web'), 2000, T);
eq('1회 실패 후 회복은 조용', [names(r.down), names(r.up)], [[], []]);
eq('회복하면 실패 횟수 초기화', r.next.web.fails, 0);

// 연속 2회면 확정하고 알린다
let d = decide(s.next, bad('web', 'TimeoutError'), 2000, T);
eq('연속 2회는 이상 확정', [names(d.down), names(d.up)], [['web'], []]);
eq('이상 확정 상태', d.next.web.ok, false);
eq('끊긴 시각은 첫 실패 시각으로', d.next.web.since, 1000);

// 이상이 이어지는 동안은 다시 알리지 않는다
let still = decide(d.next, bad('web', 'TimeoutError'), 3000, T);
eq('이상 지속 중엔 재알림 없음', [names(still.down), names(still.up)], [[], []]);

// 복구는 즉시 알리고, 지속 시간은 확정 시각이 아니라 첫 실패 시각 기준
let up = decide(still.next, ok('web'), 4000, T);
eq('복구는 즉시 알림', [names(up.down), names(up.up)], [[], ['web']]);
eq('복구 알림의 시작은 첫 실패 시각', up.up[0].since, 1000);

// 첫 배포에 🟢 도배 금지 — 처음 보는 항목이 정상이면 아무 알림도 없어야 한다
let first = decide({}, ok('web'), 1000, T);
eq('첫 실행에 정상은 조용', [names(first.down), names(first.up)], [[], []]);

// 선행 실패로 이번에 못 본 항목은 이전 상태를 유지한다
let keep = decide({ pg_cron: { ok: false, since: 5 } }, ok('web'), 1000, T);
eq('확인 못 한 항목은 상태 보존', keep.next.pg_cron, { ok: false, since: 5 });

// 기존 KV에는 fails가 없다 — 그대로 읽혀야 한다
let legacy = decide({ web: { ok: true, since: 5 } }, bad('web'), 1000, T);
eq('fails 없는 옛 상태도 처리', [legacy.next.web.ok, legacy.next.web.fails], [true, 1]);

console.log(fail ? `\n${fail}건 실패` : '\n전부 통과');
process.exit(fail ? 1 : 0);
