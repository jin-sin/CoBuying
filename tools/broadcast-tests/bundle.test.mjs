import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

test('테스트 Cloud SQL 묶음은 B01 기준에서 한 거래로 적용되고 재실행은 거절한다',async()=>{
  const db=new PGlite();
  try {
    await db.exec(`create role anon; create role authenticated; create role service_role;
      create schema auth;create schema storage;
      create table storage.objects(bucket_id text not null,name text not null,primary key(bucket_id,name));
      create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
      grant usage on schema public,auth to anon,authenticated,service_role;
      grant execute on function auth.uid() to anon,authenticated,service_role;
      create table public.seller_profiles(user_id uuid primary key references auth.users(id),status text not null);`);
    for(const name of ['202609230001_broadcast_capture.sql',
      '202609280001_broadcast_capture_management.sql',
      '202609280002_broadcast_staff_invites.sql',
      '202609280003_broadcast_paging.sql']) {
      await db.exec(await readFile(new URL(`../../supabase/migrations/${name}`,import.meta.url),'utf8'));
    }
    const sql=await readFile(new URL('../../docs/plans/broadcast-orders/generated/test-cloud-b02-b08.sql',import.meta.url),'utf8');
    assert.match(sql,/TEST PROJECT ONLY: orendam-broadcast-test/);
    await db.exec(sql);
    const row=(await db.query(`select to_regclass('public.broadcast_customer_devices')::text as devices,
      to_regclass('public.broadcast_receiver_qr_commands')::text as qr,
      to_regclass('public.broadcast_invoice_country_commands')::text as country`)).rows[0];
    assert.equal(row.devices,'broadcast_customer_devices');
    assert.equal(row.qr,'broadcast_receiver_qr_commands');
    assert.equal(row.country,'broadcast_invoice_country_commands');
    await assert.rejects(db.exec(sql),/B02 already present/);
  } finally {await db.close();}
});
