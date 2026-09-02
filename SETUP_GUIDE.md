# new+ — setup guide

An app for finding and posting jobs and gigs nearby in Uganda: register,
browse or post gigs, and message the poster directly — text, photos, and
voice notes. Manual mobile-money or Pesapal subscription, same approach
as prep+.

**Files in this folder**
- `index.html` — the user-facing app
- `admin.html` — the admin dashboard (separate page, never linked from the user app)
- `about.html`, `privacy.html`, `terms.html` — public info pages
- `manifest.json` — install/PWA metadata (name, description, icons)
- `config.js` — where you paste your Supabase keys and (optional) VAPID push key
- `style.css`, `shared.js` — shared design and logic, don't need editing
- `schema.sql` — creates all the database tables, security rules, and helper functions
- `supabase/functions/pesapal-order`, `pesapal-ipn`, `send-push` — edge functions for payments and push notifications

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

## Old messages auto-delete after 60 days

To keep database and storage usage bounded (especially on the free
tier), a daily job deletes any chat message — and its photo or voice-note
file, if it has one — once it's more than 60 days old. This runs inside
Supabase itself via `pg_cron`, so there's nothing to deploy or keep
running on your end; `schema.sql` sets it up automatically.

Statuses/posts aren't affected by this — they already auto-expire after
24 hours on their own. Nothing else (profiles, subscriptions, etc.) is
touched.

If you ever want a different window, change `interval '60 days'` (it
appears twice) in the `cleanup_old_messages()` function in `schema.sql`
and re-run the file — `cron.schedule` is set up to safely replace the
existing job rather than duplicate it.

pg_cron ships enabled on Supabase's free tier as of 2026, but if your
project doesn't have it, check **Database → Extensions** in the
dashboard — the rest of `schema.sql` still runs fine either way, it's
just this one cleanup job that needs pg_cron specifically.

## Scale fix — supports 1000+ concurrent users, re-run schema.sql and re-upload index.html

This update targets what actually limits how many people can be online at
once, rather than just database size:

- **`schema.sql`** adds an index so the directory page doesn't scan every
  row in `profiles` on every load — as always, paste the whole file into
  the SQL Editor and run it again; `create index if not exists` means
  nothing existing is touched.
- **`index.html`**: the ads banner and the statuses row used to update via
  realtime subscriptions with no filter, which meant every ad edit or
  status post was delivered to *every* connected user's browser at once —
  fine at small scale, but the thing that actually caps concurrent users
  once you're in the hundreds, since Supabase's Realtime plans cap and
  bill by messages *delivered*, not events raised. Both now poll quietly
  in the background instead (ads every 45s, statuses every 30s, and only
  while the tab is actually visible) — updates take a little longer to
  appear but no longer cost anything per connected user. The periodic
  profile-refresh poll was also slowed down and made visibility-aware,
  since it's just a fallback for the realtime profile channel, not the
  primary path.

None of this changes what anyone sees day-to-day — just re-upload
`index.html` and re-run `schema.sql`.

## If you see a white screen

Same causes as prep+: `config.js` not filled in, Anonymous Sign-ins off,
or no internet (the Supabase library loads from a CDN) — the app shows a
plain-language error for each instead of a blank page. Check the browser
console (F12) for anything else.

## Security hardening update — re-run schema.sql

This update adds server-side file size/type limits on all storage buckets
(previously only enforced client-side), a rate limit on "Forgot PIN"
requests (5 per phone per hour — mirrors the existing login lockout, and
stops someone from scripting through phone numbers to see which ones are
registered), a max length on status comments, and a database-level rule
that ad links must start with `http://` or `https://`. Just paste the
whole `schema.sql` into the SQL Editor and run it again — as always,
everything uses `create or replace` / `if not exists` / `on conflict do
update`, so nothing existing gets touched or lost. `admin.html` was also
updated to stop pulling the (bcrypt-hashed) `pin_hash` column into the
admin dashboard's browser state — it never used it, no separate action
needed, just re-upload the file.

## Scale fix #2 — the global "new message" alert, re-run schema.sql and re-upload index.html

Every online user was subscribed to a listener for new-message alerts
with no filter on which conversation it belonged to. Row-level security
already stopped anyone from actually reading a message that wasn't
theirs, so this was never a privacy leak — but Realtime still had to
check that security rule against every single connected user for every
message anyone sent, anywhere in the app. That per-user check is exactly
the kind of cost that stops scaling once you're past a few hundred
people online at once — the same shape of problem as the ads/directory
fix above, just paid in server load instead of leaked data.

Fix: a new database trigger (`broadcast_new_message`) sends a small,
targeted alert directly to the one recipient who needs it, so Realtime
never has to check anyone else. As always, paste the whole `schema.sql`
into the SQL Editor and run it again, and re-upload `index.html` — both
use `create or replace` / `drop trigger if exists`, so nothing existing
is touched.

## Voice notes capped at 1 minute — re-upload index.html

Recording now stops automatically at 60 seconds and sends what was
captured, with a toast letting the person know why. This is a
client-side limit (matches how the rest of the app already works, e.g.
image compression before upload) — it's not enforced by the database,
so treat it as a normal-use limit rather than an unbreakable one.

## Fixed: short messages breaking into one letter per line — re-upload style.css

A CSS sizing bug meant short messages (a couple of characters or a short
number) could render with every letter on its own line. The cause: the
message bubble's width limit was a percentage of its own wrapper, but
that wrapper's width was in turn calculated from the bubble's size —
each one waiting on the other, which browsers resolve by collapsing
both down to almost nothing. Fixed by moving the width limit to the
wrapper itself instead, which has an unambiguous size to measure
against. Long messages still wrap normally; only re-upload `style.css`
needed.

## Self-service PIN reset by email — re-run schema.sql patch, deploy a new edge function, re-upload index.html and admin.html

"Forgot PIN?" used to go through an admin, who verified the requester some
other way and relayed a temporary PIN by phone/WhatsApp. It's now fully
self-service: the user enters their phone + the email on their account,
gets a 6-digit code by email, and sets a new PIN themselves — no admin
step, and the "PIN resets" tab in `admin.html` is gone.

This needs everyone to have an email on file, which the app didn't collect
before. **New accounts** are asked for one at registration (required).
**Existing accounts** should add one from **My profile → Edit details** —
do this before you need it, since forgetting your PIN with no email on
file has no self-service fix (see below).

**Steps to turn this on:**

1. **SQL Editor** → paste and run `patch_email_pin_reset.sql` (a new
   file, separate from the main `schema.sql`) — adds the `email` column,
   the new reset functions, and the `pin_reset_codes` table.
2. **Sign up for Resend** (https://resend.com — free tier is plenty for
   this volume) and get an API key. For real deployment, verify a sending
   domain there so email doesn't land in spam; for quick testing you can
   skip that and use their shared `onboarding@resend.dev` sender instead.
3. **Deploy the new edge function:**
   ```
   supabase functions deploy send-pin-reset-email
   ```
4. **Set three secrets** (same pattern as the push-notification secret):
   ```
   supabase secrets set RESEND_API_KEY=<your Resend API key>
   supabase secrets set PIN_RESET_TRIGGER_SECRET=<a random string, e.g. from: openssl rand -hex 32>
   supabase secrets set RESEND_FROM_ADDRESS='newplus <you@yourdomain.com>'
   ```
   (Skip the `RESEND_FROM_ADDRESS` line to use the shared testing sender.)
5. **Set the matching database setting** (SQL Editor, same random string as step 4):
   ```sql
   alter database postgres set app.settings.pin_reset_trigger_secret = '<the same random string>';
   ```
6. **Re-upload** `index.html` and `admin.html`.

The old admin-approval path (`pin_reset_requests` table,
`admin_set_temp_pin()`) is left in the database untouched, just no longer
called by either page — a manual fallback if you ever need to help
someone who has no email on file and can't self-serve.

## Gig-marketplace copy cleanup — re-upload index.html and manifest.json

A few leftover phrases from before the pivot to a gig marketplace were
still showing: the homepage's no-JavaScript fallback text ("Make new
friends nearby") and `manifest.json`'s install description ("...as well
meet new world here"). Both are now consistent with the rest of the
site (`about.html`, `privacy.html`, `terms.html`), which already talked
about jobs and gigs throughout. Nothing else in either file changed.
