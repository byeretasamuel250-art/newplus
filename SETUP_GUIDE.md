# new+ — setup guide

An app for meeting new people nearby: register, subscribe, browse who's
around, and chat — text, photos, and GIFs. Manual mobile-money
subscription, same approach as prep+.

**Files in this folder**
- `index.html` — the user-facing app
- `admin.html` — the admin dashboard (separate page, never linked from the user app)
- `config.js` — where you paste your Supabase keys and (optional) Tenor GIF key and VAPID push key
- `style.css`, `shared.js` — shared design and logic, don't need editing
- `schema.sql` — creates all the database tables, security rules, and helper functions

Same security model as prep+: a user can only ever see their own account
details, the people directory and messaging are gated by subscription at
the database level, and every conversation's messages and photos are only
readable by the two people in it — not by other users, and not even by
the admin's regular access (only via the explicit is_admin() check).

---

## Step 1 — Create a Supabase project

Go to supabase.com → **New project** → name it, set a database password
(save it), pick a region, create it, wait ~2 minutes. (You can reuse the
same project as prep+ if you want everything in one place — the tables
won't conflict — or use a separate one; both work.)

## Step 2 — Build the database

1. **SQL Editor** → **New query**.
2. Copy all of `schema.sql`, paste it in, click **Run**.
3. You should see "Success. No rows returned."

## Step 3 — Connect the app

1. **Project Settings → API** → copy the **Project URL** and **anon public** key.
2. Paste both into `config.js`.

## Step 4 — Turn on Anonymous Sign-ins

**Authentication → Sign In / Providers → Anonymous Sign-ins → on.**
This is what lets phone + PIN work without OTP or email.

## Step 5 — (Optional) Turn on push notifications

The app works fine without this — skip it and people just won't get
notified when the app isn't open. To turn it on:

1. Generate a VAPID key pair (a one-time thing) — easiest way is
   `npx web-push generate-vapid-keys` in a terminal, or any VAPID
   keygen tool. You'll get a **public key** and a **private key**.
2. Paste the **public** key into `config.js` as `VAPID_PUBLIC_KEY`.
3. The private key is only needed if/when you deploy the server-side
   piece that actually sends the push (a Supabase Edge Function) —
   it never goes in `config.js`.
4. If you leave `VAPID_PUBLIC_KEY` as the placeholder, push notifications
   just stay off — nothing breaks, the toggle simply won't appear on the
   Edit Profile screen.

## Step 6 — (Optional but recommended) Get a free Tenor key for GIFs

1. Go to https://developers.google.com/tenor/guides/quickstart and follow
   the free API key steps (no credit card needed).
2. Paste the key into `config.js` as `TENOR_API_KEY`.
3. If you skip this, the app still works fine — the GIF button just shows
   a message saying GIFs aren't set up yet.

## Step 7 — Create your admin login

1. **Authentication → Users → Add user** — enter your email + password, leave Auto Confirm on.
2. **SQL Editor** → run (with your real email):
   ```sql
   insert into admin_allowlist (email) values ('you@example.com');
   ```
3. Open `admin.html` and log in.

## Step 8 — Test locally

```
python3 -m http.server 8080
```
Visit `http://localhost:8080`, register a test account (18+, phone number
made up is fine for local testing), finish your profile with a photo,
then register a *second* test account in a private/incognito window so
you have two people to chat between. Subscribe both (as admin, approve
the payment requests in `admin.html`), then message between them and try
sending a photo and a GIF.

## Step 9 — Publish

Same as prep+ — drag the folder onto **Netlify**, or push to **GitHub
Pages**, or **Vercel**. User link is the root URL; keep `/admin.html`
private (don't link to it from anywhere in the user app).

---

## Day to day

**Approving payments:** Payment requests tab, check your mobile money
statement, Approve. You'll hear a chime and see the browser tab flash
the moment someone taps "I've paid" — no need to keep refreshing.

**Managing users:** Users tab shows everyone, their subscription status,
and a Deactivate/Reactivate button — deactivating immediately logs them
out of new+ and blocks login until reactivated.

**PIN resets:** if a user forgets their PIN, they tap "Forgot PIN?" on
the login screen and enter their phone number, plus their date of birth
and district — this doesn't need them to be logged in. It shows up in
**PIN resets** in `admin.html`, where you'll see what they typed next to
what's actually on file, with a "matches ✓" / "mismatch ✗" flag for each.
A mismatch isn't an automatic reject — a genuine user can misremember a
detail — but it's a reason to ask more on the call. Still verify it's
really them the same way you'd trust for a payment (you know them, a
phone call, etc.), then Approve — this generates a random 4-digit
temporary PIN and pops it up on screen for you to relay to them yourself
(call, WhatsApp, in person). The moment they log in with that temporary
PIN, they're required to pick their own new PIN before they can do
anything else in the app.

**Running banner ads:** Ads tab in `admin.html` — upload an image (wide,
roughly 3:1 works best), optionally add a link, and it shows up at the
top of the directory for every user. Add several and one is shown at
random each time someone opens the app. Pause or delete anytime — no
extra setup, no third-party ad account needed.

**A user's experience:** register (phone, PIN, date of birth, district)
→ finish profile (name, photo, optional location sharing) → subscribe →
browse people sorted by distance (or district, if location isn't
shared) → tap someone → chat with text, photos, and GIFs in real time.
Anytime after that, they can go to **My profile → Edit details** to
change their name, date of birth, district, or location sharing.

**If you already ran schema.sql before:** this update adds PIN/password
recovery — a new `pin_reset_requests` table, a `pin_must_change` column
on profiles, and a few new functions — plus a `status_views` table that
lets each person's own device remember which statuses they've watched, so
the ring goes from bright to muted once they've seen everything from that
person (each viewer can only see their own view history, never anyone
else's). Just paste the whole `schema.sql` into the SQL Editor and run it
again — everything uses `create or replace` / `if not exists` / `add
column if not exists`, so nothing existing gets touched or lost. This
update also adds `submitted_dob` and `submitted_district` columns to
`pin_reset_requests`, for the new verification questions on the
forgot-PIN form.

**If you already ran schema.sql before this:** PINs now hash with bcrypt
instead of plain sha256 (sha256 is fast to compute, which is exactly the
wrong property for a secret with only 10,000 possible values — bcrypt is
deliberately slow, so it takes real time to brute-force even if the
`pin_hash` column were ever exposed). No action needed and nobody is
locked out: `login_with_pin` still recognizes the old format and quietly
upgrades each account to bcrypt the next time its owner logs in. Also,
`register_with_pin` and `login_with_pin` no longer send `pin_hash` or
`phone` back to the browser at all — the app never used those fields
client-side, so there was no reason for them to leave the database.

## About location

Users choose whether to share their location — if they do, other
subscribers see an approximate distance ("3.2 km away"), never an exact
address or map pin. If they skip it, they're just grouped by district
instead. Nothing about this is forced — it's opt-in and can be turned
off any time by not re-enabling it after logging back in with a fresh
session (a future update could add a toggle on the profile screen if you
want that sooner).

## If you see a white screen

Same causes as prep+: `config.js` not filled in, Anonymous Sign-ins off,
or no internet (the Supabase library loads from a CDN) — the app shows a
plain-language error for each instead of a blank page. Check the browser
console (F12) for anything else.
