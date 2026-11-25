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
