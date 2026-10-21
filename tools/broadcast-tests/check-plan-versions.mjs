import { readFile, access } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const plan = "docs/plans/broadcast-orders";
const read = (path) => readFile(resolve(root, path), "utf8");
const meta = JSON.parse(await read(`${plan}/version.json`));
assert.match(meta.bundle, /^v\d+\.\d+\.\d+$/);
assert.equal(meta.requirements, "v1");
const bundlePattern = meta.bundle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

const headers = [
  [`${plan}/README.md`, new RegExp(`^# 방송판매 MVP 개발 계획 ${bundlePattern}$`, "m")],
  [`${plan}/interfaces.md`, new RegExp(`^# 화면·상태·API 규약 ${bundlePattern}$`, "m")],
  [`${plan}/contracts.d.ts`, new RegExp(`^/\\*\\* ${bundlePattern} / requirements-v1`) ],
  [`${plan}/ui-coverage.md`, new RegExp(`^# 화면 커버리지 · ${bundlePattern}$`, "m")],
  ["docs/prototypes/broadcast-orders/README.md", new RegExp(`^# 방송판매 시안 ${bundlePattern}$`, "m")],
  ["docs/prototypes/broadcast-orders/index.html", new RegExp(`<title>오렌담마켓 · 방송판매 업무 시안 ${bundlePattern}</title>`) ],
  ["docs/prototypes/broadcast-orders/index.html", new RegExp(`<strong>동작 시안 ${bundlePattern}</strong`) ],
];
for (const [path, pattern] of headers) {
  assert.match(await read(path), pattern, `${path}의 공통 버전이 version.json과 다릅니다.`);
}

const register = await read(`${plan}/stage-versions.md`);
for (let n = 0; n <= 9; n++) {
  const id = `B${String(n).padStart(2, "0")}`;
  const stage = meta.stages[id];
  assert.ok(stage, `${id} 단계가 version.json에 없습니다.`);
  assert.match(register, new RegExp(`^\\| ${id} `, "m"));
  if (stage.status === "planned") {
    assert.equal(stage.version, null);
    assert.equal(stage.record, null);
  } else if (stage.status === "completed-before-versioning") {
    assert.equal(stage.version, null);
    assert.equal(stage.record, "worklog.md");
  } else {
    assert.match(stage.version, /^v\d+\.\d+\.\d+$/);
    assert.match(stage.record, new RegExp(`^versions/${id}-${stage.version}\\.md$`));
    if (stage.status === "complete") assert.match(stage.version, /^v[1-9]\d*\./);
    if (stage.status === "in-progress") assert.match(stage.version, /^v0\./);
    assert.ok(["complete", "in-progress"].includes(stage.status));
    await access(resolve(root, plan, stage.record));
    assert.match(await read(`${plan}/${stage.record}`), new RegExp(`^# ${id}-${stage.version}\\b`, "m"));
    assert.ok(register.includes(`[${stage.version}](${stage.record})`));
  }
}
assert.equal(Object.keys(meta.stages).length, 10);
const active = Object.entries(meta.stages).filter(([, stage]) => stage.status === 'in-progress')
  .map(([id, stage]) => `${id} ${stage.version}`).join(', ');
console.log(`계획 버전 일치: ${meta.bundle}; ${active}; 10개 단계`);
