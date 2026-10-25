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

-- ---------------------------------------------------------------- coins, unlocks, the pass and achievements
alter table public.players add column if not exists coins int not null default 0;
alter table public.players add column if not exists xp int not null default 0;
alter table public.players add column if not exists premium boolean not null default false;
alter table public.players add column if not exists owned text[] not null default '{}';
alter table public.players add column if not exists equipped jsonb not null default '{}';
alter table public.players add column if not exists stats jsonb not null default '{}';
alter table public.players add column if not exists claimed text[] not null default '{}';
alter table public.players add column if not exists pass_claimed text[] not null default '{}';
alter table public.players add column if not exists last_award timestamptz;
alter table public.players add column if not exists keys int not null default 0;     -- for mega crates: won in co-op and ranked only

-- add n to one counter in the stats
create or replace function public.bump(s jsonb, k text, n int) returns jsonb
language sql immutable as $$ select jsonb_set(coalesce(s, '{}'), array[k], to_jsonb(coalesce((s->>k)::int, 0) + n)) $$;

-- coins for a ranked win, by the rank of the player you beat (BEGINNER 5 ... DEMON 20)
create or replace function public.rank_coins(pts int) returns int
language sql immutable as $$
  select case when pts >= 1400 then 20 when pts >= 1000 then 15 when pts >= 700 then 12 when pts >= 450 then 10
              when pts >= 250 then 8 when pts >= 100 then 6 else 5 end
$$;

-- the shop: what's for sale (price null = battle pass only)
create table if not exists public.shop_items (id text primary key, kind text not null, rarity text not null, price int);
alter table public.shop_items enable row level security;
drop policy if exists "everyone can see the shop" on public.shop_items;
create policy "everyone can see the shop" on public.shop_items for select using (true);
insert into public.shop_items (id, kind, rarity, price) values
  ('hat_cap', 'hat', 'common', 40), ('hat_headband', 'hat', 'common', 40), ('hat_beanie', 'hat', 'common', 60), ('hat_party', 'hat', 'common', 60),
  ('hat_cowboy', 'hat', 'rare', 120), ('hat_tophat', 'hat', 'rare', 120), ('hat_horns', 'hat', 'epic', 200), ('hat_crown', 'hat', 'epic', 300),
  ('hat_halo', 'hat', 'legendary', 400), ('hat_viking', 'hat', 'legendary', null),
  ('skin_stripes', 'skin', 'common', 40), ('skin_dots', 'skin', 'common', 40), ('skin_checker', 'skin', 'rare', 80), ('skin_camo', 'skin', 'rare', 80),
  ('skin_zebra', 'skin', 'epic', 150), ('skin_chrome', 'skin', 'epic', 150), ('skin_shadow', 'skin', 'legendary', 300), ('skin_tiger', 'skin', 'legendary', null),
  ('cloak_shard', 'cloak', 'legendary', null)       -- the SHARD cloak: never sold, only given out
on conflict (id) do update set kind = excluded.kind, rarity = excluded.rarity, price = excluded.price;

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
  -- coins for the winner depend on the rank of the player they beat; both get pass XP
  update players set points = points + gain, wins = wins + 1,
    coins = coins + rank_coins(lp), xp = xp + 20, keys = keys + 1,
    stats = bump(bump(bump(stats, 'matches', 1), 'wins', 1), 'ranked_wins', 1)
    where id = winner;
  update players set points = greatest(0, points - round(gain * 0.8)::int), losses = losses + 1,
    xp = xp + 8, stats = bump(stats, 'matches', 1)
    where id = loser;
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

-- ---------------------------------------------------------------- rewards for bot and co-op matches
-- bot win: EASY 1, NORMAL 2, HARD 3 coins. Online co-op win: 6. Every match also gives battle pass XP (win 20, loss 8).
create or replace function public.award(mode text, level text, won boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.players; c int := 0; x int; k int := 0;
begin
  if mode not in ('bot', 'coop') then return null; end if;
  select * into me from players where id = auth.uid() for update;
  if not found then return null; end if;
  -- one reward per match: a match takes longer than this, so spamming it gets nothing
  if me.last_award is not null and me.last_award > now() - interval '40 seconds' then return jsonb_build_object('coins', 0, 'xp', 0, 'keys', 0); end if;
  if won then
    c := case when mode = 'coop' then 6 else (case level when 'EASY' then 1 when 'NORMAL' then 2 when 'HARD' then 3 else 0 end) end;
    if mode = 'coop' then k := 1; end if;             -- keys only come from playing people, never bots
  end if;
  x := case when won then 20 else 8 end;
  update players set coins = coins + c, xp = xp + x, keys = keys + k, last_award = now(),
    stats = bump(bump(bump(bump(bump(stats, 'matches', 1),
              'wins', case when won then 1 else 0 end),
              'bot_wins', case when won and mode = 'bot' then 1 else 0 end),
              'hard_wins', case when won and mode = 'bot' and level = 'HARD' then 1 else 0 end),
              'coop_wins', case when won and mode = 'coop' then 1 else 0 end)
    where id = me.id;
  return jsonb_build_object('coins', c, 'xp', x, 'keys', k);
end $$;

-- ---------------------------------------------------------------- the shop
create or replace function public.buy(item text) returns public.players
language plpgsql security definer set search_path = public as $$
declare me public.players; it public.shop_items;
begin
  select * into it from shop_items where id = item;
  if not found or it.price is null then raise exception 'NOT FOR SALE'; end if;
  select * into me from players where id = auth.uid() for update;
  if not found then raise exception 'NOT SIGNED IN'; end if;
  if item = any(me.owned) then raise exception 'YOU ALREADY HAVE IT'; end if;
  if me.coins < it.price then raise exception 'NOT ENOUGH COINS'; end if;
  update players set coins = coins - it.price, owned = array_append(owned, item) where id = me.id returning * into me;
  return me;
end $$;

create or replace function public.equip(slot text, item text) returns public.players
language plpgsql security definer set search_path = public as $$
declare me public.players;
begin
  if slot not in ('hat', 'skin', 'cloak') then raise exception 'NO SUCH SLOT'; end if;
  select * into me from players where id = auth.uid() for update;
  if not found then raise exception 'NOT SIGNED IN'; end if;
  if coalesce(item, '') <> '' and (not (item = any(me.owned)) or left(item, length(slot) + 1) <> slot || '_') then
    raise exception 'YOU DON''T HAVE THAT';
  end if;
  update players set equipped = jsonb_set(equipped, array[slot], to_jsonb(coalesce(item, ''))) where id = me.id returning * into me;
  return me;
end $$;

-- crates: a random item you don't have yet. CRATE: mostly common. MEGA CRATE: rare or better.
-- If you already own everything of the rarity you rolled, you get coins back instead.
create or replace function public.roll_crate(uid uuid, crate text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.players; r float := random(); rar text; pick text; refund int;
begin
  select * into me from players where id = uid for update;
  rar := case when crate = 'mega' then (case when r < .5 then 'rare' when r < .85 then 'epic' else 'legendary' end)
              else (case when r < .65 then 'common' when r < .9 then 'rare' when r < .98 then 'epic' else 'legendary' end) end;
  select id into pick from shop_items where rarity = rar and price is not null and not (id = any(me.owned)) order by random() limit 1;
  update players set stats = bump(stats, 'crates', 1) where id = uid;
  if pick is null then
    refund := case when crate = 'mega' then 60 else 15 end;
    update players set coins = coins + refund where id = uid;
    return jsonb_build_object('item', null, 'rarity', rar, 'refund', refund);
  end if;
  update players set owned = array_append(owned, pick) where id = uid;
  return jsonb_build_object('item', pick, 'rarity', rar, 'refund', 0);
end $$;
revoke execute on function public.roll_crate(uuid, text) from public, anon, authenticated;

create or replace function public.open_crate(crate text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.players;
begin
  if crate not in ('crate', 'mega') then raise exception 'NO SUCH CRATE'; end if;
  select * into me from players where id = auth.uid() for update;
  if not found then raise exception 'NOT SIGNED IN'; end if;
  -- a crate costs 30 coins; a mega crate costs 3 keys
  if crate = 'mega' then
    if me.keys < 3 then raise exception 'YOU NEED 3 KEYS - WIN CO-OP OR RANKED'; end if;
    update players set keys = keys - 3 where id = me.id;
  else
    if me.coins < 30 then raise exception 'NOT ENOUGH COINS'; end if;
    update players set coins = coins - 30 where id = me.id;
  end if;
  return roll_crate(me.id, crate);
end $$;

-- ---------------------------------------------------------------- the battle pass: 20 tiers, 100 XP each
create or replace function public.buy_premium() returns public.players
language plpgsql security definer set search_path = public as $$
declare me public.players;
begin
  select * into me from players where id = auth.uid() for update;
  if not found then raise exception 'NOT SIGNED IN'; end if;
  if me.premium then raise exception 'YOU ALREADY HAVE IT'; end if;
  if me.coins < 200 then raise exception 'NOT ENOUGH COINS'; end if;
  update players set coins = coins - 200, premium = true where id = me.id returning * into me;
  return me;
end $$;

create or replace function public.claim_tier(tier int, track text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.players; reward text; k text := track || tier; amt int;
begin
  if tier < 1 or tier > 20 or track not in ('free', 'premium') then raise exception 'NO SUCH TIER'; end if;
  select * into me from players where id = auth.uid() for update;
  if not found then raise exception 'NOT SIGNED IN'; end if;
  if me.xp < tier * 100 then raise exception 'NOT UNLOCKED YET'; end if;
  if track = 'premium' and not me.premium then raise exception 'GET THE PREMIUM PASS FIRST'; end if;
  if k = any(me.pass_claimed) then raise exception 'ALREADY CLAIMED'; end if;
  -- the same rewards the game shows (keep both lists the same)
  reward := case track
    when 'free' then (array['c10','c10','hat_headband','c15','crate','c15','skin_dots','c20','c20','crate',
                            'c20','hat_party','c25','c25','crate','c25','skin_checker','c30','c30','mega'])[tier]
    else (array['c30','hat_beanie','c30','skin_stripes','mega','c40','hat_cowboy','c40','skin_camo','mega',
                'c50','hat_tophat','c50','skin_zebra','mega','c60','hat_crown','skin_tiger','c80','hat_viking'])[tier] end;
  update players set pass_claimed = array_append(pass_claimed, k) where id = me.id;
  if reward ~ '^c[0-9]+$' then
    amt := substr(reward, 2)::int;
    update players set coins = coins + amt where id = me.id;
    return jsonb_build_object('kind', 'coins', 'amount', amt);
  elsif reward in ('crate', 'mega') then
    return jsonb_build_object('kind', 'crate', 'crate', reward) || roll_crate(me.id, reward);
  elsif reward = any(me.owned) then          -- already have it: coins instead
    update players set coins = coins + 50 where id = me.id;
    return jsonb_build_object('kind', 'coins', 'amount', 50);
  end if;
  update players set owned = array_append(owned, reward) where id = me.id;
  return jsonb_build_object('kind', 'item', 'item', reward);
end $$;

-- ---------------------------------------------------------------- achievements: claim the coins once you've done them
create or replace function public.claim_achievement(aid text) returns public.players
language plpgsql security definer set search_path = public as $$
declare me public.players; st jsonb; done boolean; reward int;
begin
  select * into me from players where id = auth.uid() for update;
  if not found then raise exception 'NOT SIGNED IN'; end if;
  if aid = any(me.claimed) then raise exception 'ALREADY CLAIMED'; end if;
  st := me.stats;
  select x.done, x.reward into done, reward from (values
    ('first_win',  coalesce((st->>'wins')::int, 0) >= 1, 10),
    ('bot_10',     coalesce((st->>'bot_wins')::int, 0) >= 10, 20),
    ('hard_5',     coalesce((st->>'hard_wins')::int, 0) >= 5, 30),
    ('coop_5',     coalesce((st->>'coop_wins')::int, 0) >= 5, 30),
    ('ranked_1',   coalesce((st->>'ranked_wins')::int, 0) >= 1, 15),
    ('amateur',    me.points >= 100, 30),
    ('medalist',   me.points >= 450, 60),
    ('demon',      me.points >= 1400, 200),
    ('vet_50',     coalesce((st->>'matches')::int, 0) >= 50, 50),
    ('collect_10', cardinality(me.owned) >= 10, 40),
    ('crates_10',  coalesce((st->>'crates')::int, 0) >= 10, 30)
  ) as x(id, done, reward) where x.id = aid;
  if reward is null then raise exception 'NO SUCH ACHIEVEMENT'; end if;
  if not done then raise exception 'NOT DONE YET'; end if;
  update players set coins = coins + reward, claimed = array_append(claimed, aid) where id = me.id returning * into me;
  return me;
end $$;
