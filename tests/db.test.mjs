import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';

const db = new PGlite();
const A = '11111111-1111-1111-1111-111111111111';
const B = '22222222-2222-2222-2222-222222222222';
const S = '33333333-3333-3333-3333-333333333333';

await db.exec(`
create role anon nologin; create role authenticated nologin;
create schema auth;
create table auth.users(id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
create schema storage;
create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name,'/'))[1:array_length(string_to_array(name,'/'),1)-1] $$;
insert into auth.users values ('${A}','a@x.in'),('${B}','b@x.in'),('${S}','s@startuptn.in');
`);
let sql = fs.readFileSync(process.argv[2], 'utf8').replace(/create extension[^;]*;/, '');
await db.exec(sql);
await db.exec(`
grant usage on schema public, auth, storage to authenticated, anon;
grant all on all tables in schema public to authenticated;
grant usage on all sequences in schema public to authenticated;
revoke all on sequence public.app_no_seq from authenticated;
grant all on storage.objects to authenticated;
grant execute on all functions in schema auth to authenticated;
insert into public.staff(user_id,email,full_name,role) values ('${S}','s@startuptn.in','Staff One','admin');
`);

let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('  ok  ', m); } else { fail++; console.log('  FAIL', m); } };
async function as(uid, fn) {
  await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub','${uid}',false);`);
  try { return await fn(); } finally { await db.exec(`reset role; select set_config('request.jwt.claim.sub','',false);`); }
}
const q = (s, p) => db.query(s, p);
const err = async (p) => { try { await p; return null; } catch (e) { return e.message; } };

// 1. applicant creates a draft and cannot self-submit
const appId = await as(A, async () => {
  const r = await q(`insert into applications(legal_name, applicant_email) values ('Kaveri Agro Pvt Ltd','a@x.in') returning id, status, applicant_id`);
  ok(r.rows[0].status === 'draft' && r.rows[0].applicant_id === A, 'draft created and owned by applicant');
  await q(`update applications set status='submitted', app_no='HACK' where id=$1`, [r.rows[0].id]);
  const c = await q(`select status, app_no from applications where id=$1`, [r.rows[0].id]);
  ok(c.rows[0].status === 'draft' && c.rows[0].app_no === null, 'applicant cannot set status or app number');
  return r.rows[0].id;
});

// 2. equity below threshold
await as(A, async () => {
  await q(`insert into founders(application_id, full_name, community, equity_pct, has_control, position) values ($1,'Murugan','SC',30,true,0),($1,'Investor','Other',70,false,1)`, [appId]);
  const e = await err(q(`select submit_application($1)`, [appId]));
  ok(e && e.includes('more than 50% of equity (currently 30.00%)'), 'blocks submit at 30% SC/ST equity');
  ok(e && e.includes('community certificate') && e.includes('pitch deck'), 'lists missing certificate and documents');
});

// 3. exactly 50% still blocked
await as(A, async () => {
  await q(`update founders set equity_pct=50 where application_id=$1 and community='SC'`, [appId]);
  await q(`update founders set equity_pct=50 where application_id=$1 and community='Other'`, [appId]);
  const e = await err(q(`select submit_application($1)`, [appId]));
  ok(e && e.includes('currently 50.00%'), 'blocks submit at exactly 50%');
});

// 4. combined SC + ST above 50%, control with a non-SC/ST founder only -> blocked
await as(A, async () => {
  await q(`update founders set equity_pct=35, has_control=false where application_id=$1 and community='SC'`, [appId]);
  await q(`update founders set equity_pct=45, has_control=true where application_id=$1 and community='Other'`, [appId]);
  await q(`insert into founders(application_id, full_name, community, equity_pct, has_control, position) values ($1,'Selvi','ST',20,false,2)`, [appId]);
  const e = await err(q(`select submit_application($1)`, [appId]));
  ok(e && !e.includes('more than 50%') && e.includes('management control'), 'combined 55% passes equity, but control must sit with SC/ST');
});

// 5. storage: own folder ok, other folder refused
await as(A, async () => {
  const good = await err(q(`insert into storage.objects(bucket_id,name) values ('application-docs','${A}/${appId}/cert.pdf')`));
  ok(good === null, 'applicant can upload to own folder');
  const bad = await err(q(`insert into storage.objects(bucket_id,name) values ('application-docs','${B}/x/cert.pdf')`));
  ok(bad !== null, 'applicant cannot upload to another folder');
  const bad2 = await err(q(`insert into storage.objects(bucket_id,name) values ('application-docs','staff/${appId}/im.pdf')`));
  ok(bad2 !== null, 'applicant cannot upload to staff folder');
});

// 6. complete everything and submit
const appNo = await as(A, async () => {
  await q(`update founders set has_control=true where application_id=$1 and community='SC'`, [appId]);
  await q(`update founders set cert_path=$2, cert_name='cert.pdf' where application_id=$1 and community in ('SC','ST')`, [appId, `${A}/${appId}/cert.pdf`]);
  for (const k of ['pitch_deck','incorporation','cap_table'])
    await q(`insert into documents(application_id, kind, path, file_name) values ($1,$2,$3,$4)`, [appId, k, `${A}/${appId}/${k}.pdf`, k + '.pdf']);
  const fake = await err(q(`insert into documents(application_id, kind, path, uploaded_by_staff) values ($1,'im','staff/x.pdf',true)`, [appId]));
  ok(fake !== null, 'applicant cannot add a staff document');
  await q(`update applications set entity_type='Private Limited', incorporation_date='2024-04-01', address='Hosur Rd', district='Krishnagiri',
     sector='AgriTech', stage='early', problem='p', solution='s', business_model='b', revenue_model='r', ask_amount=5000000,
     control_details='Murugan is Managing Director', declare_control=true, declare_accurate=true, declare_no_duplicate=true,
     consent_processing=true, consent_sharing=true where id=$1`, [appId]);
  const r = await q(`select submit_application($1) as no`, [appId]);
  ok(/^SCST-\d{4}-0001$/.test(r.rows[0].no), 'submit succeeds and assigns ' + r.rows[0].no);
  const c = await q(`select consent_at is not null as c from applications where id=$1`, [appId]);
  ok(c.rows[0].c, 'consent time recorded');
  const again = await err(q(`select submit_application($1)`, [appId]));
  ok(again && again.includes('already been submitted'), 'cannot submit twice');
  await q(`update applications set legal_name='Changed' where id=$1`, [appId]);
  const n = await q(`select legal_name from applications where id=$1`, [appId]);
  ok(n.rows[0].legal_name === 'Kaveri Agro Pvt Ltd', 'applicant cannot edit after submitting');
  const f = await err(q(`update founders set equity_pct=1 where application_id=$1`, [appId]));
  const fv = await q(`select min(equity_pct) m from founders where application_id=$1`, [appId]);
  ok(Number(fv.rows[0].m) === 20, 'founders locked after submitting');
  const rv = await q(`select * from reviews`);
  ok(rv.rows.length === 0, 'applicant cannot see the review pipeline');
  return r.rows[0].no;
});

// 7. other applicant sees nothing
await as(B, async () => {
  const r = await q(`select * from applications`);
  ok(r.rows.length === 0, 'another applicant cannot see this application');
  const d = await q(`select * from documents`);
  ok(d.rows.length === 0, 'another applicant cannot see documents');
  const s = await q(`select * from storage.objects`);
  ok(s.rows.length === 0, 'another applicant cannot list files');
});

// 8. staff
await as(S, async () => {
  const r = await q(`select a.app_no, r.stage, r.status from applications a join reviews r on r.application_id=a.id`);
  ok(r.rows.length === 1 && r.rows[0].stage === 'validation' && r.rows[0].app_no === appNo, 'staff sees submitted application at validation');
  await q(`update reviews set stage='pitch', data = data || '{"validation":{"outcome":"accepted"}}' where application_id=$1`, [appId]);
  const r2 = await q(`select stage, updated_by from reviews where application_id=$1`, [appId]);
  ok(r2.rows[0].stage === 'pitch' && r2.rows[0].updated_by === S, 'staff can move stage; updated_by recorded');
  await q(`insert into activity(application_id, text) values ($1,'Eligibility validated')`, [appId]);
  const a = await q(`select count(*)::int n from activity where application_id=$1`, [appId]);
  ok(a.rows[0].n === 2, 'staff writes and reads activity');
  const so = await err(q(`insert into storage.objects(bucket_id,name) values ('application-docs','staff/${appId}/im.pdf')`));
  ok(so === null, 'staff can upload to staff folder');
  const sd = await err(q(`insert into documents(application_id, kind, path, uploaded_by_staff) values ($1,'im',$2,true)`, [appId, `staff/${appId}/im.pdf`]));
  ok(sd === null, 'staff can register a staff document');
  const files = await q(`select count(*)::int n from storage.objects`);
  ok(files.rows[0].n === 2, 'staff can read all files');
  await q(`update applications set legal_name='Staff edit' where id=$1`, [appId]);
  const n = await q(`select legal_name from applications where id=$1`, [appId]);
  ok(n.rows[0].legal_name === 'Kaveri Agro Pvt Ltd', 'staff cannot alter what the applicant submitted');
});

// 9. applicant cannot see staff documents
await as(A, async () => {
  const d = await q(`select kind from documents where application_id=$1`, [appId]);
  ok(d.rows.every(x => x.kind !== 'im'), 'applicant does not see staff documents such as the IM');
});

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
