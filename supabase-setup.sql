-- TRIGGER ranked: the database.
-- Paste ALL of this into Supabase > SQL Editor > New query, then press Run. It's safe to run again.

-- players: one row per player, made the first time they open Ranked
create table if not exists public.players (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  points int not null default 0,
  wins int not null default 0,
  losses int not null default 0,
  created_at timestamptz not null default now()
);

-- queue: players waiting for a ranked match (each one is hosting a PeerJS room)
create table if not exists public.queue (
  player uuid primary key references public.players(id) on delete cascade,
  room text not null,
  points int not null,
  updated_at timestamptz not null default now()
);

-- matches: who played who, and who each side says won
create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  host uuid not null references public.players(id) on delete cascade,
  guest uuid not null references public.players(id) on delete cascade,
  host_report uuid,
  guest_report uuid,
  first_report_at timestamptz,
  settled boolean not null default false,
  created_at timestamptz not null default now()
);

-- Security: anyone can read the players list (for the leaderboard), you can see your own matches,
-- and NOBODY can write to the tables directly. Only the functions below change anything.
alter table public.players enable row level security;
alter table public.queue enable row level security;
alter table public.matches enable row level security;
drop policy if exists "everyone can see players" on public.players;
create policy "everyone can see players" on public.players for select using (true);
drop policy if exists "players see their own matches" on public.matches;
create policy "players see their own matches" on public.matches for select using (auth.uid() = host or auth.uid() = guest);

-- names: everyone's is different (ignoring capitals), and a player picks theirs once
alter table public.players add column if not exists named boolean not null default false;
create unique index if not exists players_name_unique on public.players (upper(name));

-- your player, made the first time you open Ranked, with a stand-in name like PLAYER 4821 until you pick one
create or replace function public.ensure_player() returns public.players
language plpgsql security definer set search_path = public as $$
declare me public.players;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into me from players where id = auth.uid();
  if not found then
    for i in 1..20 loop          -- try again if that number is already taken
      begin
        insert into players (id, name) values (auth.uid(), 'PLAYER ' || (1000 + floor(random() * 9000))::int)
        returning * into me;
        exit;
      exception when unique_violation then null;
      end;
    end loop;
  end if;
  return me;
end $$;

-- pick your ranked name (once): 3-12 letters or numbers, not rude, not taken
create or replace function public.set_name(new_name text) returns public.players
language plpgsql security definer set search_path = public as $$
declare me public.players; n text; squashed text; bad text;
begin
  if auth.uid() is null then raise exception 'NOT SIGNED IN'; end if;
  n := upper(btrim(regexp_replace(coalesce(new_name, ''), '\s+', ' ', 'g')));
  if n !~ '^[A-Z0-9 ]{3,12}$' then raise exception 'USE 3-12 LETTERS OR NUMBERS'; end if;
  if n like 'PLAYER%' then raise exception 'PICK A DIFFERENT NAME'; end if;
  -- rude words, even hidden with spaces or numbers for letters
  squashed := translate(replace(n, ' ', ''), '013457', 'OIEAST');
  foreach bad in array array['FUCK','FUK','SHIT','BITCH','CUNT','DICK','COCK','PUSSY','PENIS','VAGINA','NIGG','NIGA',
                            'FAG','RAPE','PORN','SEX','NAZI','HITLER','KKK','SLUT','WHORE','ASSHOLE','RETARD','WANK','TWAT','BOOB'] loop
    if position(bad in squashed) > 0 then raise exception 'PICK A DIFFERENT NAME'; end if;
  end loop;
  select * into me from players where id = auth.uid();
  if not found then raise exception 'OPEN RANKED FIRST'; end if;
  if me.named then raise exception 'YOU ALREADY PICKED A NAME'; end if;
  if exists (select 1 from players where upper(name) = n and id <> auth.uid()) then raise exception 'THAT NAME IS TAKEN'; end if;
  update players set name = n, named = true where id = auth.uid() returning * into me;
  return me;
end $$;

-- the points: more for beating someone ranked above you, fewer for beating someone below you
create or replace function public.apply_result(match_id uuid, winner uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.matches; loser uuid; wp int; lp int; gain int;
begin
  select * into m from matches where id = match_id for update;
  if not found or m.settled then return; end if;
  loser := case when winner = m.host then m.guest else m.host end;
  select points into wp from players where id = winner;
  select points into lp from players where id = loser;
  gain := greatest(5, round(40 * (1 - 1 / (1 + power(10, (lp - wp) / 400.0)))))::int;
  update players set points = points + gain, wins = wins + 1 where id = winner;
  update players set points = greatest(0, points - round(gain * 0.8)::int), losses = losses + 1 where id = loser;
  update matches set settled = true where id = match_id;
end $$;
-- players can't call apply_result themselves: only the functions here can
revoke execute on function public.apply_result(uuid, uuid) from public, anon, authenticated;

-- a match where only one side ever reported (the other quit): after 3 minutes, the one who stayed wins
create or replace function public.settle_stale() returns void
language plpgsql security definer set search_path = public as $$
declare m public.matches;
begin
  for m in select * from matches where not settled and first_report_at < now() - interval '3 minutes' loop
    if m.host_report is not null and m.guest_report is null then perform apply_result(m.id, m.host_report);
    elsif m.guest_report is not null and m.host_report is null then perform apply_result(m.id, m.guest_report);
    end if;
  end loop;
  -- tidy up matches nobody ever finished
  update matches set settled = true where not settled and first_report_at is null and created_at < now() - interval '1 hour';
end $$;

-- after a match, each player sends in who won. Points only change when both say the same thing.
create or replace function public.report_result(match_id uuid, winner uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.matches;
begin
  select * into m from matches where id = match_id for update;
  if not found or m.settled then return; end if;
  if winner <> m.host and winner <> m.guest then return; end if;
  if auth.uid() = m.host then
    update matches set host_report = winner, first_report_at = coalesce(first_report_at, now()) where id = match_id;
  elsif auth.uid() = m.guest then
    update matches set guest_report = winner, first_report_at = coalesce(first_report_at, now()) where id = match_id;
  else
    return;
  end if;
  select * into m from matches where id = match_id;
  if m.host_report is not null and m.guest_report is not null then
    if m.host_report = m.guest_report then perform apply_result(match_id, m.host_report);
    else update matches set settled = true where id = match_id;      -- they disagree: nobody's points change
    end if;
  end if;
end $$;

-- join the queue: if someone's waiting (closest in points first), you're matched with them;
-- otherwise you wait, hosting your own room
create or replace function public.queue_up(room text) returns json
language plpgsql security definer set search_path = public as $$
declare me public.players; other public.queue; mid uuid;
begin
  me := ensure_player();
  perform settle_stale();
  select * into other from queue
    where player <> me.id and updated_at > now() - interval '30 seconds'
    order by abs(points - me.points), updated_at
    limit 1 for update skip locked;
  if found then
    delete from queue where player in (other.player, me.id);
    insert into matches (host, guest) values (other.player, me.id) returning id into mid;
    return json_build_object('role', 'guest', 'room', other.room, 'match', mid, 'host', other.player);
  end if;
  insert into queue (player, room, points) values (me.id, room, me.points)
    on conflict (player) do update set room = excluded.room, points = excluded.points, updated_at = now();
  return json_build_object('role', 'host');
end $$;

create or replace function public.leave_queue() returns void
language sql security definer set search_path = public as $$
  delete from queue where player = auth.uid();
$$;
