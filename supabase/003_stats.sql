-- =====================================================================
-- Owambe Survivor: update 003, analytics events + private /stats page
-- Run once in Supabase SQL Editor (safe to re-run).
-- IMPORTANT: change CHANGE-ME below to your own secret passcode before running.
-- The /stats page asks for this passcode. The dashboard stays locked while it is CHANGE-ME.
-- =====================================================================

create table if not exists public.events (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  device     text not null,      -- random id per browser, no personal data
  player_id  uuid,               -- the anonymous Supabase user, if signed in
  kind       text not null,      -- visit, game_start, game_end, dance_end, buy, share, ...
  mode       text,
  mc         text,
  venue      text,
  value      integer,            -- e.g. naira haul or price
  secs       integer,            -- e.g. seconds played
  info       text,               -- small extra detail: traffic source, item id, reason
  mobile     boolean
);
create index if not exists events_at_idx   on public.events (at desc);
create index if not exists events_kind_idx on public.events (kind, at desc);
create index if not exists events_dev_idx  on public.events (device, at desc);

create table if not exists public.admin_config (key text primary key, value text not null);

alter table public.events       enable row level security;
alter table public.admin_config enable row level security;
revoke all on public.events, public.admin_config from anon, authenticated;

-- your stats passcode (change CHANGE-ME, keep the quotes)
insert into public.admin_config(key, value) values ('stats_code', 'CHANGE-ME')
on conflict (key) do update set value = excluded.value;

create or replace function public.log_event(
  p_device text, p_kind text, p_mode text default null, p_mc text default null, p_venue text default null,
  p_value integer default null, p_info text default null, p_mobile boolean default null, p_secs integer default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_device is null or length(p_device) > 40 or p_kind !~ '^[a-z_]{2,24}$' then return; end if;
  if (select count(*) from events where device = p_device and at > now() - interval '1 minute') >= 40 then return; end if;
  insert into events(device, player_id, kind, mode, mc, venue, value, secs, info, mobile)
  values (left(p_device, 40), auth.uid(), p_kind, left(p_mode, 16), left(p_mc, 24), left(p_venue, 16),
          p_value, p_secs, left(p_info, 80), p_mobile);
end $$;

create or replace function public.get_stats(p_code text, p_days integer default 14) returns json
language plpgsql security definer set search_path = public as $$
declare
  t date := lagos_today();
  since timestamptz := ((t - (greatest(p_days, 7) - 1))::timestamp at time zone 'Africa/Lagos');
  wk timestamptz := ((t - 6)::timestamp at time zone 'Africa/Lagos');
  td timestamptz := (t::timestamp at time zone 'Africa/Lagos');
  r json;
begin
  if not exists (select 1 from admin_config where key = 'stats_code' and value = p_code and value <> 'CHANGE-ME') then
    raise exception 'Wrong passcode';
  end if;
  select json_build_object(
    'generated_at', now(),
    'today', (select json_build_object(
        'visitors', count(distinct device) filter (where kind = 'visit'),
        'players',  count(distinct device) filter (where kind = 'game_start'),
        'games',    count(*) filter (where kind = 'game_end'),
        'shares',   count(*) filter (where kind in ('share', 'challenge_create')))
      from events where at >= td),
    'week', (select json_build_object(
        'visitors', count(distinct device) filter (where kind = 'visit'),
        'players',  count(distinct device) filter (where kind = 'game_start'),
        'games',    count(*) filter (where kind = 'game_end'),
        'finished', count(distinct device) filter (where kind = 'game_end'),
        'shares',   count(*) filter (where kind in ('share', 'challenge_create')),
        'sharers',  count(distinct device) filter (where kind in ('share', 'challenge_create')),
        'mobile',   count(distinct device) filter (where kind = 'visit' and mobile),
        'avg_haul', round(avg(value) filter (where kind = 'game_end')),
        'best_haul', max(value) filter (where kind = 'game_end'),
        'avg_secs', round(avg(secs) filter (where kind = 'game_end')),
        'dance_wins', count(*) filter (where kind = 'dance_end' and info = 'win'),
        'dances',  count(*) filter (where kind = 'dance_end'))
      from events where at >= wk),
    'all', (select json_build_object(
        'visitors', count(distinct device) filter (where kind = 'visit'),
        'players',  count(distinct device) filter (where kind = 'game_start'),
        'games',    count(*) filter (where kind = 'game_end'),
        'since',    min(at))
      from events),
    'returning', (select count(*) from (
        select device from events where kind = 'visit' and at >= wk
        group by device having count(distinct (at at time zone 'Africa/Lagos')::date) >= 2) x),
    'daily', (select coalesce(json_agg(x order by x.d), '[]'::json) from (
        select (at at time zone 'Africa/Lagos')::date as d,
               count(distinct device) filter (where kind = 'visit') as v,
               count(distinct device) filter (where kind = 'game_start') as p,
               count(*) filter (where kind = 'game_end') as g
        from events where at >= since group by 1) x),
    'sources', (select coalesce(json_agg(x), '[]'::json) from (
        select coalesce(info, 'direct') as name, count(distinct device) as n
        from events where kind = 'visit' and at >= wk group by 1 order by 2 desc limit 8) x),
    'links', (select coalesce(json_agg(x), '[]'::json) from (
        select coalesce(mc, 'main site') as name,
               count(distinct device) filter (where kind = 'visit') as visitors,
               count(*) filter (where kind = 'game_end') as games
        from events where at >= wk and kind in ('visit', 'game_end')
        group by 1 order by 2 desc limit 8) x),
    'modes', (select coalesce(json_agg(x), '[]'::json) from (
        select coalesce(mode, '?') as name, count(*) as n from events
        where kind = 'game_end' and at >= wk group by 1 order by 2 desc) x),
    'buys', (select coalesce(json_agg(x), '[]'::json) from (
        select info as name, count(*) as n, sum(value) as naira from events
        where kind = 'buy' and at >= wk group by 1 order by 2 desc limit 10) x),
    'top_players', (select coalesce(json_agg(x), '[]'::json) from (
        select coalesce(p.nickname, 'Guest') as name, max(s.haul) as best, count(*) as games
        from scores s join players p on p.id = s.player_id
        group by p.id, p.nickname order by 2 desc limit 10) x),
    'named_players', (select count(*) from players where nickname is not null),
    'recent', (select coalesce(json_agg(x), '[]'::json) from (
        select at, kind, mode, mc, value, info, mobile from events
        where kind <> 'visit' or at >= now() - interval '2 hours'
        order by at desc limit 30) x)
  ) into r;
  return r;
end $$;

grant execute on function public.log_event(text, text, text, text, text, integer, text, boolean, integer) to anon, authenticated;
grant execute on function public.get_stats(text, integer) to anon, authenticated;
