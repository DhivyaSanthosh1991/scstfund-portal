-- =====================================================================
-- TN SC/ST Startup Fund — application portal + review pipeline
-- Run once in the Supabase SQL editor (Project → SQL Editor → New query).
-- Safe to re-run: objects are created only if missing, policies replaced.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Staff (StartupTN fund team). Add rows here to give someone access to
-- the review pipeline. See README → "Add staff".
-- ---------------------------------------------------------------------
create table if not exists public.staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  full_name  text,
  role       text not null default 'reviewer' check (role in ('reviewer','admin')),
  created_at timestamptz not null default now()
);

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid());
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid() and role = 'admin');
$$;

-- ---------------------------------------------------------------------
-- Applications (filled in by the startup)
-- ---------------------------------------------------------------------
create sequence if not exists public.app_no_seq;

create table if not exists public.applications (
  id                 uuid primary key default gen_random_uuid(),
  applicant_id       uuid not null unique default auth.uid() references auth.users(id) on delete cascade,
  applicant_email    text,
  status             text not null default 'draft' check (status in ('draft','submitted')),
  app_no             text unique,
  submitted_at       timestamptz,

  -- 1. Startup
  legal_name         text,
  brand_name         text,
  entity_type        text,
  cin                text,
  incorporation_date date,
  address            text,
  district           text,
  pincode            text,
  dpiit_no           text,
  startuptn_id       text,
  gstin              text,
  sector             text,
  website            text,
  stage              text check (stage is null or stage in ('idea','prototype','early','growth')),

  -- 4. Business
  problem            text,
  solution           text,
  business_model     text,
  revenue_model      text,
  target_customers   text,
  competitors        text,
  usp                text,
  scalability        text,
  traction           text,

  -- 5. Financials
  revenue_history    jsonb not null default '[]'::jsonb,   -- [{fy, revenue}]
  monthly_revenue    numeric,
  funds_raised       jsonb not null default '[]'::jsonb,   -- [{source, amount, instrument, year}]
  existing_loans     text,

  -- 6. Team
  fulltime_employees integer check (fulltime_employees is null or fulltime_employees >= 0),
  key_team           text,

  -- 7. Funding ask
  ask_amount         numeric check (ask_amount is null or ask_amount >= 0),
  utilisation        jsonb not null default '[]'::jsonb,   -- [{head, amount}]
  milestones         jsonb not null default '[]'::jsonb,   -- [{milestone, month}]

  -- 3. Control + 9. Declarations
  control_details        text,
  declare_control        boolean not null default false,
  declare_accurate       boolean not null default false,
  declare_no_duplicate   boolean not null default false,
  consent_processing     boolean not null default false,
  consent_sharing        boolean not null default false,
  consent_at             timestamptz,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- Applicants can never set status, application number or submission time
-- themselves; only submit_application() can (it sets scst.allow_status).
create or replace function public.applications_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.applicant_id := auth.uid(); end if;
    new.status := 'draft'; new.app_no := null; new.submitted_at := null;
  elsif coalesce(current_setting('scst.allow_status', true), '') <> 'on' then
    new.status := old.status; new.app_no := old.app_no;
    new.submitted_at := old.submitted_at; new.applicant_id := old.applicant_id;
  end if;
  if new.consent_processing and new.consent_sharing and new.consent_at is null then
    new.consent_at := now();
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists applications_guard on public.applications;
create trigger applications_guard before insert or update on public.applications
  for each row execute function public.applications_guard();

-- ---------------------------------------------------------------------
-- Founders (one row per founder / shareholder-founder)
-- ---------------------------------------------------------------------
create table if not exists public.founders (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete cascade,
  position       integer not null default 0,
  full_name      text,
  designation    text,
  email          text,
  phone          text,
  community      text check (community is null or community in ('SC','ST','Other')),
  equity_pct     numeric(5,2) check (equity_pct is null or (equity_pct >= 0 and equity_pct <= 100)),
  has_control    boolean not null default false,   -- holds operational / management control
  background     text,
  linkedin       text,
  cert_path      text,                              -- community certificate in storage
  cert_name      text,
  created_at     timestamptz not null default now()
);
create index if not exists founders_app_idx on public.founders(application_id);

-- ---------------------------------------------------------------------
-- Documents (applicant uploads and staff uploads such as the IM)
-- ---------------------------------------------------------------------
create table if not exists public.documents (
  id               uuid primary key default gen_random_uuid(),
  application_id   uuid not null references public.applications(id) on delete cascade,
  kind             text not null,
  uploaded_by_staff boolean not null default false,
  path             text not null,
  file_name        text,
  size_bytes       bigint,
  uploaded_by      uuid default auth.uid(),
  uploaded_at      timestamptz not null default now()
);
create index if not exists documents_app_idx on public.documents(application_id);

-- ---------------------------------------------------------------------
-- Review pipeline (StartupTN only — applicants never see these tables)
-- ---------------------------------------------------------------------
create table if not exists public.reviews (
  application_id uuid primary key references public.applications(id) on delete cascade,
  stage          text not null default 'validation'
                 check (stage in ('validation','pitch','bdd','ic','psc','term_sheet','dd','ssha','funded')),
  status         text not null default 'active'
                 check (status in ('active','rejected','msme','declined','funded')),
  stage_since    timestamptz not null default now(),
  data           jsonb not null default '{}'::jsonb,
  closed_reason  text,
  closed_at_step text,
  closed_at      timestamptz,
  updated_at     timestamptz not null default now(),
  updated_by     uuid default auth.uid()
);

create table if not exists public.activity (
  id             bigserial primary key,
  application_id uuid not null references public.applications(id) on delete cascade,
  at             timestamptz not null default now(),
  actor          uuid default auth.uid(),
  actor_label    text,
  text           text not null
);
create index if not exists activity_app_idx on public.activity(application_id, at desc);

-- ---------------------------------------------------------------------
-- Submit: validates the application server-side, assigns the number,
-- and opens it in the review pipeline at Phase 1 validation.
-- ---------------------------------------------------------------------
create or replace function public.submit_application(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  a       public.applications;
  errs    text[] := '{}';
  n_f     integer; total numeric; scst numeric; n_ctrl integer;
  no      text;
begin
  select * into a from public.applications where id = p_id for update;
  if not found or a.applicant_id is distinct from auth.uid() then
    raise exception 'Application not found';
  end if;
  if a.status <> 'draft' then
    raise exception 'This application has already been submitted';
  end if;

  if coalesce(trim(a.legal_name),'') = ''      then errs := array_append(errs, 'startup legal name'); end if;
  if coalesce(trim(a.entity_type),'') = ''     then errs := array_append(errs, 'entity type'); end if;
  if a.incorporation_date is null              then errs := array_append(errs, 'date of incorporation'); end if;
  if coalesce(trim(a.address),'') = ''         then errs := array_append(errs, 'registered address'); end if;
  if coalesce(trim(a.district),'') = ''        then errs := array_append(errs, 'district'); end if;
  if coalesce(trim(a.sector),'') = ''          then errs := array_append(errs, 'sector'); end if;
  if a.stage is null                           then errs := array_append(errs, 'stage of the startup'); end if;
  if coalesce(trim(a.problem),'') = ''         then errs := array_append(errs, 'problem'); end if;
  if coalesce(trim(a.solution),'') = ''        then errs := array_append(errs, 'solution'); end if;
  if coalesce(trim(a.business_model),'') = ''  then errs := array_append(errs, 'business model'); end if;
  if coalesce(trim(a.revenue_model),'') = ''   then errs := array_append(errs, 'revenue model'); end if;
  if coalesce(a.ask_amount,0) <= 0             then errs := array_append(errs, 'funding amount requested'); end if;
  if coalesce(trim(a.control_details),'') = '' then errs := array_append(errs, 'how management control is held'); end if;
  if not (a.declare_control and a.declare_accurate and a.declare_no_duplicate
          and a.consent_processing and a.consent_sharing) then
    errs := array_append(errs, 'all declarations and consents');
  end if;

  select count(*),
         coalesce(sum(equity_pct),0),
         coalesce(sum(equity_pct) filter (where community in ('SC','ST')),0),
         count(*) filter (where community in ('SC','ST') and has_control)
    into n_f, total, scst, n_ctrl
    from public.founders where application_id = p_id;

  if n_f = 0 then errs := array_append(errs, 'at least one founder'); end if;
  if exists (select 1 from public.founders where application_id = p_id
             and (coalesce(trim(full_name),'') = '' or community is null or equity_pct is null)) then
    errs := array_append(errs, 'name, community and shareholding for every founder');
  end if;
  if total > 100 then
    errs := array_append(errs, format('founder shareholding adds up to %s%%, which is more than 100%%', total));
  end if;
  if scst <= 50 then
    errs := array_append(errs, format('SC/ST founders must together hold more than 50%% of equity (currently %s%%)', scst));
  end if;
  if n_ctrl = 0 then
    errs := array_append(errs, 'at least one SC/ST founder holding operational and management control');
  end if;
  if exists (select 1 from public.founders where application_id = p_id
             and community in ('SC','ST') and cert_path is null) then
    errs := array_append(errs, 'community certificate for every SC/ST founder');
  end if;
  if not exists (select 1 from public.documents where application_id = p_id and kind = 'pitch_deck' and not uploaded_by_staff) then
    errs := array_append(errs, 'pitch deck');
  end if;
  if not exists (select 1 from public.documents where application_id = p_id and kind = 'incorporation' and not uploaded_by_staff) then
    errs := array_append(errs, 'certificate of incorporation');
  end if;
  if not exists (select 1 from public.documents where application_id = p_id and kind = 'cap_table' and not uploaded_by_staff) then
    errs := array_append(errs, 'shareholding pattern / cap table');
  end if;

  if array_length(errs, 1) > 0 then
    raise exception 'Please complete: %', array_to_string(errs, '; ') using errcode = 'P0001';
  end if;

  perform set_config('scst.allow_status', 'on', true);
  no := 'SCST-' || to_char(now() at time zone 'Asia/Kolkata', 'YYYY') || '-' || lpad(nextval('public.app_no_seq')::text, 4, '0');
  update public.applications set status = 'submitted', app_no = no, submitted_at = now() where id = p_id;
  perform set_config('scst.allow_status', '', true);

  insert into public.reviews (application_id, updated_by) values (p_id, null) on conflict do nothing;
  insert into public.activity (application_id, actor, actor_label, text)
    values (p_id, auth.uid(), 'Applicant', 'Application submitted as ' || no);
  return no;
end $$;

revoke all on function public.submit_application(uuid) from public, anon;
grant execute on function public.submit_application(uuid) to authenticated;
revoke all on sequence public.app_no_seq from anon, authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.staff        enable row level security;
alter table public.applications enable row level security;
alter table public.founders     enable row level security;
alter table public.documents    enable row level security;
alter table public.reviews      enable row level security;
alter table public.activity     enable row level security;

-- staff: team members see the team list (for names in the activity log)
drop policy if exists staff_read on public.staff;
create policy staff_read on public.staff for select to authenticated using (public.is_staff());

-- applications
drop policy if exists app_owner_read   on public.applications;
drop policy if exists app_owner_insert on public.applications;
drop policy if exists app_owner_update on public.applications;
drop policy if exists app_staff_read   on public.applications;
create policy app_owner_read   on public.applications for select to authenticated using (applicant_id = auth.uid());
create policy app_owner_insert on public.applications for insert to authenticated with check (applicant_id = auth.uid());
create policy app_owner_update on public.applications for update to authenticated
  using (applicant_id = auth.uid() and status = 'draft') with check (applicant_id = auth.uid());
create policy app_staff_read   on public.applications for select to authenticated using (public.is_staff());

-- helper: is this application the caller's own draft?
create or replace function public.is_own_draft(p_app uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.applications where id = p_app and applicant_id = auth.uid() and status = 'draft');
$$;
create or replace function public.is_own_app(p_app uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.applications where id = p_app and applicant_id = auth.uid());
$$;

-- founders
drop policy if exists f_owner_read  on public.founders;
drop policy if exists f_owner_write on public.founders;
drop policy if exists f_staff_read  on public.founders;
create policy f_owner_read  on public.founders for select to authenticated using (public.is_own_app(application_id));
create policy f_owner_write on public.founders for all to authenticated
  using (public.is_own_draft(application_id)) with check (public.is_own_draft(application_id));
create policy f_staff_read  on public.founders for select to authenticated using (public.is_staff());

-- documents
drop policy if exists d_owner_read   on public.documents;
drop policy if exists d_owner_insert on public.documents;
drop policy if exists d_owner_delete on public.documents;
drop policy if exists d_staff_read   on public.documents;
drop policy if exists d_staff_insert on public.documents;
drop policy if exists d_admin_delete on public.documents;
create policy d_owner_read   on public.documents for select to authenticated
  using (public.is_own_app(application_id) and not uploaded_by_staff);
create policy d_owner_insert on public.documents for insert to authenticated
  with check (public.is_own_draft(application_id) and not uploaded_by_staff and split_part(path, '/', 1) = auth.uid()::text);
create policy d_owner_delete on public.documents for delete to authenticated
  using (public.is_own_draft(application_id) and not uploaded_by_staff);
create policy d_staff_read   on public.documents for select to authenticated using (public.is_staff());
create policy d_staff_insert on public.documents for insert to authenticated
  with check (public.is_staff() and uploaded_by_staff and split_part(path, '/', 1) = 'staff');
create policy d_admin_delete on public.documents for delete to authenticated using (public.is_admin() and uploaded_by_staff);

-- reviews + activity: staff only
drop policy if exists r_staff_read   on public.reviews;
drop policy if exists r_staff_update on public.reviews;
create policy r_staff_read   on public.reviews for select to authenticated using (public.is_staff());
create policy r_staff_update on public.reviews for update to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists a_staff_read   on public.activity;
drop policy if exists a_staff_insert on public.activity;
create policy a_staff_read   on public.activity for select to authenticated using (public.is_staff());
create policy a_staff_insert on public.activity for insert to authenticated
  with check (public.is_staff() and actor = auth.uid());

-- keep reviews.updated_at / updated_by current
create or replace function public.reviews_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); new.updated_by := coalesce(auth.uid(), new.updated_by); return new; end $$;
drop trigger if exists reviews_touch on public.reviews;
create trigger reviews_touch before update on public.reviews for each row execute function public.reviews_touch();

-- ---------------------------------------------------------------------
-- Storage: one private bucket. Applicants write under <their user id>/,
-- staff write under staff/. Nothing is public; files open via signed URLs.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('application-docs', 'application-docs', false, 20971520,
        array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "scst applicant upload" on storage.objects;
drop policy if exists "scst applicant read"   on storage.objects;
drop policy if exists "scst applicant delete" on storage.objects;
drop policy if exists "scst staff read"       on storage.objects;
drop policy if exists "scst staff upload"     on storage.objects;

create policy "scst applicant upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'application-docs'
              and (storage.foldername(name))[1] = auth.uid()::text
              and exists (select 1 from public.applications where applicant_id = auth.uid() and status = 'draft'));
create policy "scst applicant read" on storage.objects for select to authenticated
  using (bucket_id = 'application-docs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "scst applicant delete" on storage.objects for delete to authenticated
  using (bucket_id = 'application-docs' and (storage.foldername(name))[1] = auth.uid()::text
         and exists (select 1 from public.applications where applicant_id = auth.uid() and status = 'draft'));
create policy "scst staff read" on storage.objects for select to authenticated
  using (bucket_id = 'application-docs' and public.is_staff());
create policy "scst staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'application-docs' and (storage.foldername(name))[1] = 'staff' and public.is_staff());

-- =====================================================================
-- Hardening (applied to the live project as migration scst_fund_harden_helpers)
-- Moves policy helpers to a private schema and closes API-exposed functions.
-- =====================================================================
create schema if not exists private;
grant usage on schema private to authenticated;

create or replace function private.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid());
$$;
create or replace function private.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid() and role = 'admin');
$$;
create or replace function private.is_own_draft(p_app uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.applications where id = p_app and applicant_id = auth.uid() and status = 'draft');
$$;
create or replace function private.is_own_app(p_app uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.applications where id = p_app and applicant_id = auth.uid());
$$;
revoke all on function private.is_staff(), private.is_admin(), private.is_own_draft(uuid), private.is_own_app(uuid) from public, anon;
grant execute on function private.is_staff(), private.is_admin(), private.is_own_draft(uuid), private.is_own_app(uuid) to authenticated;

drop policy if exists staff_read on public.staff;
create policy staff_read on public.staff for select to authenticated using (private.is_staff());

drop policy if exists app_staff_read on public.applications;
create policy app_staff_read on public.applications for select to authenticated using (private.is_staff());

drop policy if exists f_owner_read  on public.founders;
drop policy if exists f_owner_write on public.founders;
drop policy if exists f_staff_read  on public.founders;
create policy f_owner_read  on public.founders for select to authenticated using (private.is_own_app(application_id));
create policy f_owner_write on public.founders for all to authenticated
  using (private.is_own_draft(application_id)) with check (private.is_own_draft(application_id));
create policy f_staff_read  on public.founders for select to authenticated using (private.is_staff());

drop policy if exists d_owner_read   on public.documents;
drop policy if exists d_owner_insert on public.documents;
drop policy if exists d_owner_delete on public.documents;
drop policy if exists d_staff_read   on public.documents;
drop policy if exists d_staff_insert on public.documents;
drop policy if exists d_admin_delete on public.documents;
create policy d_owner_read   on public.documents for select to authenticated
  using (private.is_own_app(application_id) and not uploaded_by_staff);
create policy d_owner_insert on public.documents for insert to authenticated
  with check (private.is_own_draft(application_id) and not uploaded_by_staff and split_part(path, '/', 1) = auth.uid()::text);
create policy d_owner_delete on public.documents for delete to authenticated
  using (private.is_own_draft(application_id) and not uploaded_by_staff);
create policy d_staff_read   on public.documents for select to authenticated using (private.is_staff());
create policy d_staff_insert on public.documents for insert to authenticated
  with check (private.is_staff() and uploaded_by_staff and split_part(path, '/', 1) = 'staff');
create policy d_admin_delete on public.documents for delete to authenticated using (private.is_admin() and uploaded_by_staff);

drop policy if exists r_staff_read   on public.reviews;
drop policy if exists r_staff_update on public.reviews;
create policy r_staff_read   on public.reviews for select to authenticated using (private.is_staff());
create policy r_staff_update on public.reviews for update to authenticated using (private.is_staff()) with check (private.is_staff());

drop policy if exists a_staff_read   on public.activity;
drop policy if exists a_staff_insert on public.activity;
create policy a_staff_read   on public.activity for select to authenticated using (private.is_staff());
create policy a_staff_insert on public.activity for insert to authenticated
  with check (private.is_staff() and actor = auth.uid());

drop policy if exists "scst staff read"   on storage.objects;
drop policy if exists "scst staff upload" on storage.objects;
create policy "scst staff read" on storage.objects for select to authenticated
  using (bucket_id = 'application-docs' and private.is_staff());
create policy "scst staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'application-docs' and (storage.foldername(name))[1] = 'staff' and private.is_staff());

drop function if exists public.is_staff();
drop function if exists public.is_admin();
drop function if exists public.is_own_draft(uuid);
drop function if exists public.is_own_app(uuid);

alter function public.applications_guard() set search_path = public;
alter function public.reviews_touch() set search_path = public;

revoke all on public.staff, public.applications, public.founders, public.documents, public.reviews, public.activity from anon;
revoke execute on function public.submit_application(uuid) from public, anon;
grant execute on function public.submit_application(uuid) to authenticated;
