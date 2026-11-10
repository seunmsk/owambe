-- =====================================================================
-- Owambe Survivor: update 004, "Playing right now" on the /stats page
-- Run once in Supabase SQL Editor after 003 (safe to re-run). Your passcode is unchanged.
-- =====================================================================

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
    'now', (select json_build_object(
        'online',  count(*),
        'playing', count(*) filter (where k in ('game_start','dance_end') or (k = 'ping' and i = 'playing')),
        'list', coalesce(json_agg(json_build_object('at', a, 'state', case when k in ('game_start','dance_end') or (k = 'ping' and i = 'playing') then 'playing' when k = 'game_end' then 'just finished' else 'on the menu' end,
                 'mode', m, 'mc', l, 'mobile', mob) order by a desc), '[]'::json))
      from (select distinct on (device) device, kind as k, info as i, mode as m, mc as l, mobile as mob, at as a
            from events where at >= now() - interval '2 minutes' order by device, at desc) live),
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
        where kind <> 'ping' and (kind <> 'visit' or at >= now() - interval '2 hours')
        order by at desc limit 30) x)
  ) into r;
  return r;
end $$;

grant execute on function public.get_stats(text, integer) to anon, authenticated;
