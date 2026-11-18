-- May's Hair Studio (owambe.pages.dev/may): progress tracking for Seun's private dashboard.
-- Run once in Supabase → SQL Editor. Uses the same stats passcode as the Owambe dashboard.

create table if not exists public.salon_events (
  id bigserial primary key,
  at timestamptz not null default now(),
  device text not null,
  kind text not null,
  data jsonb not null default '{}'::jsonb
);
create index if not exists salon_events_at on public.salon_events (at desc);
create index if not exists salon_events_dev on public.salon_events (device, at desc);
alter table public.salon_events enable row level security;
revoke all on public.salon_events from anon, authenticated;

create or replace function public.salon_log(p_device text, p_kind text, p_data jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_device is null or length(p_device) > 40 or p_kind not in ('open', 'client', 'unlock', 'ping') then return; end if;
  if octet_length(coalesce(p_data, '{}'::jsonb)::text) > 16000 then return; end if;
  if (select count(*) from salon_events where device = p_device and at > now() - interval '1 minute') >= 20 then return; end if;
  insert into salon_events (device, kind, data) values (p_device, p_kind, coalesce(p_data, '{}'::jsonb));
end $$;
revoke all on function public.salon_log(text, text, jsonb) from public;
grant execute on function public.salon_log(text, text, jsonb) to anon, authenticated;

create or replace function public.get_salon(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare r json;
begin
  if not exists (select 1 from admin_config where key = 'stats_code' and value = p_code and value <> 'CHANGE-ME') then
    raise exception 'Wrong passcode';
  end if;
  select json_build_object(
    'online', (select count(distinct device) from salon_events where at > now() - interval '2 minutes'),
    'players', coalesce((select json_agg(p order by p.last_seen desc) from (
        select e.device, min(e.at) as first_seen, max(e.at) as last_seen,
               count(*) filter (where e.kind = 'open') as opens,
               count(*) filter (where e.kind = 'client') as clients,
               count(distinct (e.at at time zone 'Africa/Lagos')::date) as days_played,
               (select x.data from salon_events x where x.device = e.device and x.kind in ('open', 'client')
                 order by x.at desc limit 1) - 'thumb' as latest
        from salon_events e group by e.device) p), '[]'::json),
    'daily', coalesce((select json_agg(d order by d.day) from (
        select (at at time zone 'Africa/Lagos')::date as day,
               count(*) filter (where kind = 'open') as opens,
               count(*) filter (where kind = 'client') as clients
        from salon_events where at > now() - interval '14 days' group by 1) d), '[]'::json),
    'clients', coalesce((select json_agg(c order by c.at desc) from (
        select at, device, data from salon_events where kind = 'client' order by at desc limit 60) c), '[]'::json),
    'unlocks', coalesce((select json_agg(u order by u.at desc) from (
        select at, device, data from salon_events where kind = 'unlock' order by at desc limit 30) u), '[]'::json)
  ) into r;
  return r;
end $$;
revoke all on function public.get_salon(text) from public;
grant execute on function public.get_salon(text) to anon, authenticated;
