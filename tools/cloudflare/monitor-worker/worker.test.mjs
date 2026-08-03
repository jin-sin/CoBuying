// 시간대 판정 테스트 — node tools/cloudflare/monitor-worker/worker.test.mjs
//
// 점검창(02:00~08:00)과 무음창(23:00~08:00)은 자정을 넘느냐 아니냐가 갈려서
// 부호 하나로 조용히 틀리기 쉽다. 틀리면 장애를 놓치거나 새벽에 폰이 울린다.
import { inWindow, kstMinutes, minutesSince, heartbeatCheck } from './worker.js';

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

// pg_cron 유예 판정용 — 창이 끝난 뒤 얼마나 지났나
eq('창 종료 5분 후', minutesSince(at('23:05'), '08:00'), 5);
eq('창 종료 3시간 후', minutesSince(at('02:00'), '08:00'), 180);
eq('창 종료 직전(거의 하루)', minutesSince(at('22:55'), '08:00'), 1435);

eq('하트비트 신선',
   heartbeatCheck({ heartbeat_age: { db_backup: 3600 } }, 'db_backup', 'DB 백업', 93600),
   { ok: true });
eq('하트비트 없음 (한 번도 안 돎)',
   heartbeatCheck({ heartbeat_age: {} }, 'db_backup', 'DB 백업', 93600),
   { ok: false, detail: 'DB 백업: 기록 없음 (한 번도 실행 안 됨)' });
eq('하트비트 만료',
   heartbeatCheck({ heartbeat_age: { db_backup: 100000 } }, 'db_backup', 'DB 백업', 93600),
   { ok: false, detail: 'DB 백업: 마지막 성공 28시간 전' });

console.log(fail ? `\n${fail}건 실패` : '\n전부 통과');
process.exit(fail ? 1 : 0);
