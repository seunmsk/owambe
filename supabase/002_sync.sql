-- =====================================================================
-- Owambe Survivor: update 002, play on phone + laptop with one progress
-- Run once in Supabase SQL Editor (safe to re-run).
-- Devices are linked with a short code. Every linked device signs in
-- anonymously as usual, then maps to one shared player.
-- =====================================================================

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
