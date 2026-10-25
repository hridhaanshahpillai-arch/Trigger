# Setting up Ranked (about 10 minutes)

Everything else in TRIGGER already works. Ranked just needs somewhere online to keep everyone's points. Do this whenever you feel like it.

## 1. Make the database
1. Go to **supabase.com** and sign up (free; signing in with GitHub is easiest).
2. Click **New project**. Name it `trigger`, make up a database password (you won't need it again), pick the region closest to you, and click **Create**. Wait a minute while it sets up.
3. On the left, click **SQL Editor**, then **New query**.
4. Open `supabase-setup.sql` (it's in the Trigger folder), copy **everything**, paste it in, and click **Run**. It should say "Success".

## 2. Let players in without signing up
1. On the left, click **Authentication**, then **Sign In / Providers** (it may be under **Settings**).
2. Turn on **Allow anonymous sign-ins** and save.

## 3. Connect the game
1. On the left, click **Project Settings** (the gear), then **API** (or **Data API**).
2. Copy the **Project URL** and the **anon public** key.
3. Open `index.html`, find these two lines near the "ranked" section, and paste them between the quotes:
   ```
   const SUPABASE_URL = '';
   const SUPABASE_KEY = '';
   ```
   The anon key is meant to be public; it's fine for it to be in the game.

Or just send me the two values and I'll paste them in for you.

## 4. Keep it awake (when TRIGGER is on GitHub)
Free Supabase projects fall asleep after a week with nobody playing. The file `.github/workflows/keep-supabase-awake.yml` wakes it every day.
1. Put the Trigger folder on GitHub, the same way you did SHARD.
2. On the repo page: **Settings → Secrets and variables → Actions → New repository secret**. Add two:
   - `SUPABASE_URL`: your Project URL
   - `SUPABASE_KEY`: your anon public key
3. Go to the **Actions** tab, click **Keep Supabase awake**, then **Run workflow** to test it. A green tick means it works.

GitHub turns off daily jobs if a repo has no changes for 60 days. If that happens, GitHub emails you, and one click turns it back on.

## If it ever does fall asleep
Log into supabase.com, open the project, and click **Restore**. Nobody's points are lost.
