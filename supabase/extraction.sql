create table if not exists public.extraction_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null,
  kind       text not null,
  created_at timestamptz not null default now()
);
create index if not exists extraction_log_user_time on public.extraction_log (user_id, created_at desc);
-- RLS on with no policies: only the edge function (service role) can read or write it.
alter table public.extraction_log enable row level security;
revoke all on public.extraction_log from anon, authenticated;
