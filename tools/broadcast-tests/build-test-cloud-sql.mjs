import {readdir, readFile, writeFile, mkdir} from 'node:fs/promises';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const migrationDir=join(root,'supabase/migrations');
const files=(await readdir(migrationDir))
  .filter(name=>name.endsWith('_broadcast_customer_access.sql') ||
    (/^202609(28|29)\d{4}_broadcast_.*\.sql$/.test(name) &&
     name>='202609280004_broadcast_customer_access.sql'))
  .sort();
if (files[0]!=='202609280004_broadcast_customer_access.sql' ||
    files.at(-1)!=='202609290012_broadcast_invoice_full_exclusion.sql') {
  throw new Error('테스트 Cloud 마이그레이션 시작/끝 파일을 확인해주세요.');
}
const chunks=[];
for (const file of files) {
  let sql=await readFile(join(migrationDir,file),'utf8');
  if (!/^\s*begin;\s*$/im.test(sql) || !/\ncommit;\s*$/i.test(sql)) {
    throw new Error(`${file}: transaction wrapper missing`);
  }
  sql=sql.replace(/^\s*begin;\s*$/im,'').replace(/\ncommit;\s*$/i,'');
  chunks.push(`\n-- ===== ${file} =====\n${sql.trim()}\n`);
}
const output=join(root,'docs/plans/broadcast-orders/generated/test-cloud-b02-b08.sql');
const header=`-- TEST PROJECT ONLY: orendam-broadcast-test (kshysvfxcjtixfveimai).
-- Apply in the test project's SQL Editor after visually checking the project label.
-- Requires the existing B01 baseline; stops when B02 is already present.
-- Run the separate Storage bucket SQL files after this transaction.
begin;
do $$ begin
 if to_regclass('public.broadcast_sessions') is null then
  raise exception 'B01 baseline missing'; end if;
 if to_regclass('public.broadcast_customer_devices') is not null then
  raise exception 'B02 already present; inspect applied migrations before retrying'; end if;
end $$;
`;
await mkdir(dirname(output),{recursive:true});
await writeFile(output,`${header}${chunks.join('')}\ncommit;\n`);
process.stdout.write(`${output}\n${files.length} migrations bundled\n`);
