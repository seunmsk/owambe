-- =====================================================================
-- Owambe Survivor: Supabase schema
-- Run this whole file once in Supabase: Dashboard > SQL Editor > New query.
-- Safe to re-run: functions are replaced, tables are created only if missing.
-- Players sign in anonymously (no email), so also enable:
--   Authentication > Sign In / Providers > "Allow anonymous sign-ins"
-- =====================================================================

-- ---------- tables ----------
create table if not exists public.players (
  id          uuid primary key references auth.users(id) on delete cascade,
  nickname    text check (nickname is null or nickname ~ '^[A-Za-z0-9_ ]{3,16}$'),
  created_at  timestamptz not null default now()
);
create unique index if not exists players_nickname_lower on public.players (lower(nickname));

create table if not exists public.scores (
  id             bigserial primary key,
  player_id      uuid not null references public.players(id) on delete cascade,
  mode           text not null check (mode in ('daily','free','challenge')),
  day_key        date not null,
  seed           bigint,
  haul           integer not null check (haul >= 0),
  caught         integer not null default 0,
  best_combo     integer not null default 0,
  escaped        integer not null default 0,
  duration_s     real not null,
  mc             text,
  outfit         text,
  challenge_code text,
  created_at     timestamptz not null default now()
);
create index if not exists scores_daily_idx   on public.scores (mode, day_key, haul desc);
create index if not exists scores_player_idx  on public.scores (player_id, created_at desc);
create index if not exists scores_mc_idx      on public.scores (mc, day_key);

create table if not exists public.challenges (
  code        text primary key,
  creator_id  uuid not null references public.players(id) on delete cascade,
  mode        text not null,
  day_key     date not null,
  seed        bigint not null,
  venue       text not null,
  mod         text not null,
  mc          text not null,
  haul        integer not null,
  created_at  timestamptz not null default now()
);

-- ---------- security: read-only tables, all writes go through the functions below ----------
alter table public.players    enable row level security;
alter table public.scores     enable row level security;
alter table public.challenges enable row level security;

drop policy if exists "players are public"    on public.players;
drop policy if exists "scores are public"     on public.scores;
drop policy if exists "challenges are public" on public.challenges;
create policy "players are public"    on public.players    for select using (true);
create policy "scores are public"     on public.scores     for select using (true);
create policy "challenges are public" on public.challenges for select using (true);

revoke insert, update, delete on public.players, public.scores, public.challenges from anon, authenticated;

-- ---------- helpers ----------
create or replace function public.lagos_today() returns date
language sql stable as $$ select (now() at time zone 'Africa/Lagos')::date $$;

create or replace function public.ensure_player() returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  insert into players(id) values (uid) on conflict (id) do nothing;
  return uid;
end $$;

-- ---------- nickname ----------
create or replace function public.set_nickname(p_nick text) returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid := ensure_player(); clean text := btrim(p_nick);
begin
  if clean !~ '^[A-Za-z0-9_ ]{3,16}$' then
    raise exception 'Nickname must be 3-16 letters, numbers, spaces or _';
  end if;
  update players set nickname = clean where id = uid;
  return clean;
exception when unique_violation then
  raise exception 'That nickname is taken';
end $$;

-- ---------- submit a finished party ----------
create or replace function public.submit_score(
  p_mode text, p_day date, p_seed bigint, p_haul integer,
  p_caught integer, p_combo integer, p_escaped integer, p_duration real,
  p_mc text, p_outfit text, p_challenge text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := ensure_player();
  t date := lagos_today();
  d date;
  last_at timestamptz;
  my_best integer; r integer; total integer;
begin
  if p_mode not in ('daily','free','challenge') then raise exception 'Bad mode'; end if;
  if p_mode = 'daily' and (p_day < t - 1 or p_day > t + 1) then raise exception 'That party is over'; end if;
  if p_duration < 5 or p_duration > 3600 then raise exception 'Bad duration'; end if;
  -- basic sanity cap: nobody earns faster than this (dance-offs included)
  if p_haul < 0 or p_haul > p_duration * 9000 + 60000 then raise exception 'Score out of range'; end if;

  select max(created_at) into last_at from scores where player_id = uid;
  if last_at is not null and last_at > now() - interval '8 seconds' then raise exception 'Too fast'; end if;

  d := case when p_mode = 'daily' then p_day else t end;
  insert into scores(player_id, mode, day_key, seed, haul, caught, best_combo, escaped, duration_s, mc, outfit, challenge_code)
  values (uid, p_mode, d, p_seed, p_haul, greatest(p_caught,0), greatest(p_combo,0), greatest(p_escaped,0), p_duration,
          left(p_mc, 32), left(p_outfit, 32), left(p_challenge, 12));

  if p_mode = 'daily' then
    select max(haul) into my_best from scores where player_id = uid and mode = 'daily' and day_key = d;
    select count(*) + 1 into r from (
      select max(haul) as b from scores where mode = 'daily' and day_key = d group by player_id
    ) x where x.b > my_best;
    select count(distinct player_id) into total from scores where mode = 'daily' and day_key = d;
    return json_build_object('rank', r, 'total', total, 'best', my_best);
  end if;
  return json_build_object('rank', null, 'total', null, 'best', null);
end $$;

-- ---------- leaderboards (best haul per player, daily parties only) ----------
-- p_scope: 'today' | 'week' | 'all'      p_mc: filter to one MC's parties (MC leaderboards)
create or replace function public.get_leaderboard(
  p_scope text, p_day date default null, p_mc text default null, p_limit integer default 50
) returns table(rank bigint, nickname text, haul integer, outfit text, is_me boolean)
language sql stable security definer set search_path = public as $$
  with s as (
    select player_id, haul, outfit, created_at from scores
    where mode = 'daily'
      and (p_scope <> 'today' or day_key = coalesce(p_day, lagos_today()))
      and (p_scope <> 'week'  or day_key > coalesce(p_day, lagos_today()) - 7)
      and (p_mc is null or mc = p_mc)
  ), b as (
    select distinct on (player_id) player_id, haul, outfit
    from s order by player_id, haul desc, created_at asc
  )
  select rank() over (order by b.haul desc), coalesce(p.nickname, 'Guest'), b.haul, b.outfit, b.player_id = auth.uid()
  from b join players p on p.id = b.player_id
  order by b.haul desc
  limit least(greatest(p_limit, 1), 100);
$$;

-- ---------- challenge a friend ----------
create or replace function public.create_challenge(
  p_mode text, p_day date, p_seed bigint, p_venue text, p_mod text, p_mc text, p_haul integer
) returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid := ensure_player(); c text; tries int := 0;
begin
  if p_haul < 0 or p_haul > 5000000 then raise exception 'Bad haul'; end if;
  if (select count(*) from challenges where creator_id = uid and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Slow down small';
  end if;
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from challenges where code = c);
    tries := tries + 1;
    if tries > 10 then raise exception 'Try again'; end if;
  end loop;
  insert into challenges(code, creator_id, mode, day_key, seed, venue, mod, mc, haul)
  values (c, uid, p_mode, coalesce(p_day, lagos_today()), p_seed, left(p_venue, 20), left(p_mod, 20), left(p_mc, 32), p_haul);
  return c;
end $$;

create or replace function public.get_challenge(p_code text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'code', c.code, 'mode', c.mode, 'day', c.day_key, 'seed', c.seed, 'venue', c.venue,
    'mod', c.mod, 'mc', c.mc, 'haul', c.haul, 'nickname', coalesce(p.nickname, 'A friend'))
  from challenges c join players p on p.id = c.creator_id
  where c.code = upper(btrim(p_code));
$$;

grant execute on function public.set_nickname(text) to authenticated;
grant execute on function public.submit_score(text,date,bigint,integer,integer,integer,integer,real,text,text,text) to authenticated;
grant execute on function public.get_leaderboard(text,date,text,integer) to anon, authenticated;
grant execute on function public.create_challenge(text,date,bigint,text,text,text,integer) to authenticated;
grant execute on function public.get_challenge(text) to anon, authenticated;

-- ---------- cross-device sync (also shipped as 002_sync.sql) ----------
create table if not exists public.device_links (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  player_id  uuid not null references public.players(id) on delete cascade,
  linked_at  timestamptz not null default now()
);
create table if not exists public.player_saves (
  player_id  uuid primary key references public.players(id) on delete cascade,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.link_codes (
  code       text primary key,
  player_id  uuid not null references public.players(id) on delete cascade,
  expires_at timestamptz not null
);
-- private tables: no policies, only reachable through the functions below
alter table public.device_links enable row level security;
alter table public.player_saves enable row level security;
alter table public.link_codes   enable row level security;
revoke all on public.device_links, public.player_saves, public.link_codes from anon, authenticated;

-- which player is this device playing as?
create or replace function public.my_player() returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); pid uuid;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select player_id into pid from device_links where user_id = uid;
  if pid is not null then return pid; end if;
  insert into players(id) values (uid) on conflict (id) do nothing;
  return uid;
end $$;

-- every existing function already calls ensure_player(), so linked devices just work
create or replace function public.ensure_player() returns uuid
language plpgsql security definer set search_path = public as $$
begin return my_player(); end $$;

create or replace function public.get_leaderboard(
  p_scope text, p_day date default null, p_mc text default null, p_limit integer default 50
) returns table(rank bigint, nickname text, haul integer, outfit text, is_me boolean)
language sql stable security definer set search_path = public as $$
  with me as (
    select coalesce((select player_id from device_links where user_id = auth.uid()), auth.uid()) as pid
  ), s as (
    select player_id, haul, outfit, created_at from scores
    where mode = 'daily'
      and (p_scope <> 'today' or day_key = coalesce(p_day, lagos_today()))
      and (p_scope <> 'week'  or day_key > coalesce(p_day, lagos_today()) - 7)
      and (p_mc is null or mc = p_mc)
  ), b as (
    select distinct on (player_id) player_id, haul, outfit
    from s order by player_id, haul desc, created_at asc
  )
  select rank() over (order by b.haul desc), coalesce(p.nickname, 'Guest'), b.haul, b.outfit, b.player_id = (select pid from me)
  from b join players p on p.id = b.player_id
  order by b.haul desc
  limit least(greatest(p_limit, 1), 100);
$$;

-- progress (bank, wardrobe, streak, level...) stored per player
create or replace function public.get_save() returns json
language plpgsql security definer set search_path = public as $$
declare pid uuid := my_player(); d jsonb;
begin
  select data into d from player_saves where player_id = pid;
  return json_build_object('player_id', pid, 'nickname', (select nickname from players where id = pid), 'data', d);
end $$;

create or replace function public.put_save(p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare pid uuid := my_player();
begin
  if octet_length(p_data::text) > 30000 then raise exception 'Save too large'; end if;
  insert into player_saves(player_id, data, updated_at) values (pid, p_data, now())
  on conflict (player_id) do update set data = excluded.data, updated_at = now();
end $$;

-- step 1, on the device that has the progress: get a code (valid 15 minutes)
create or replace function public.create_link_code() returns text
language plpgsql security definer set search_path = public as $$
declare pid uuid := my_player(); c text; i int; tries int := 0;
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  delete from link_codes where expires_at < now();
  if (select count(*) from link_codes where player_id = pid) >= 5 then
    raise exception 'Too many codes. Wait a few minutes';
  end if;
  loop
    c := '';
    for i in 1..8 loop c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1); end loop;
    exit when not exists (select 1 from link_codes where code = c);
    tries := tries + 1; if tries > 10 then raise exception 'Try again'; end if;
  end loop;
  insert into link_codes(code, player_id, expires_at) values (c, pid, now() + interval '15 minutes');
  return c;
end $$;

-- step 2, on the other device: enter the code. This device's scores move to the shared player.
create or replace function public.use_link_code(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); target uuid; old uuid; oldnick text;
  clean text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select player_id into target from link_codes where code = clean and expires_at > now();
  if target is null then raise exception 'That code is wrong or expired'; end if;
  old := my_player();
  if old <> target then
    update scores        set player_id  = target where player_id  = old;
    update challenges    set creator_id = target where creator_id = old;
    update device_links  set player_id  = target where player_id  = old;
    insert into device_links(user_id, player_id) values (uid, target)
      on conflict (user_id) do update set player_id = excluded.player_id, linked_at = now();
    if old = uid then
      select nickname into oldnick from players where id = old;
      delete from players where id = old;
      update players set nickname = coalesce(nickname, oldnick) where id = target;
    end if;
  end if;
  delete from link_codes where code = clean;
  return json_build_object('player_id', target, 'nickname', (select nickname from players where id = target));
end $$;

grant execute on function public.my_player() to authenticated;
grant execute on function public.get_save() to authenticated;
grant execute on function public.put_save(jsonb) to authenticated;
grant execute on function public.create_link_code() to authenticated;
grant execute on function public.use_link_code(text) to authenticated;
