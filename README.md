# Owambe Survivor: Naira Rain 💸

A no-install Lagos party arcade game. Catch the naira the big men are spraying, dodge the aunties ("when are you bringing your own person?"), avoid fake ₦5000 notes, and win the MC's dance-off.

**Features**
- **Today's Owambe:** a new party every day, the same for everyone (venue, MC host, twist, and note pattern are seeded by date)
- **Streaks** with rewards at 3, 7, 14 and 30 days
- **Bank and wardrobe:** everything you catch is banked and spent on outfits (agbada, buba & sokoto, senator, iro & buba, oleku, ankara gown, gele, fila, gobi, accessories, aso-oke and lace)
- **MC host** with hype lines and money-rain moments, plus a **dance-off** (Legwork, Zanku, Shaku, Gbese)
- **Four venues** with Afrobeats or Amapiano grooves (original, built in code: no licensing needed)
- **Online (Supabase):** anonymous sign-in, nicknames, daily, weekly and all-time leaderboards, and "challenge a friend" links that replay the exact same party

Everything is one static page (`index.html`). There is no build step.

## Run it locally
Open `index.html` in a browser, or serve the folder:
```
python3 -m http.server 8000
```
then visit http://localhost:8000.

## Set up Supabase (leaderboards and challenges)
1. Create a free project at https://supabase.com.
2. **SQL Editor > New query:** paste all of `supabase/schema.sql` and click **Run**.
3. **Authentication > Sign In / Providers:** turn on **Allow anonymous sign-ins**.
4. **Project Settings > API:** copy the **Project URL** and the **anon public** key into `config.js`.
5. Commit and push. The game detects the keys and goes online automatically.

Optional, recommended before a big launch: turn on CAPTCHA protection for sign-ins (Authentication > Attack Protection) so bots can't spam anonymous accounts.

### How the data is protected
- Tables are read-only to the public (row-level security). All writes go through database functions.
- `submit_score` rejects impossible scores (over a per-second cap), stale daily parties, and rapid-fire submissions.
- Nicknames are unique (case-insensitive) and limited to 3–16 letters, numbers, spaces or `_`.

## Deploy (Cloudflare Pages)
Live at **https://owambe.pages.dev/**. Cloudflare is connected to this repo: every push to `main` deploys automatically.
Settings: framework preset **None**, build command **empty**, build output directory **/**.
A custom domain can be added in Cloudflare under the project's **Custom domains** tab.

## Adding things
- **MCs:** edit the `MCS` list in `index.html` (name, colours, catchphrases, `voice` clips per moment, optional `img`). Only feature real MCs with their written permission.
- **Music:** put licensed MP3s next to `index.html` and set `TRACKS.afro` / `TRACKS.piano` to their file names.
