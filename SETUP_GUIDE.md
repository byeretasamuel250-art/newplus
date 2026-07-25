# new+ — setup guide

An app for meeting new people nearby: register, subscribe, browse who's
around, and chat — text, photos, and GIFs. Manual mobile-money
subscription, same approach as prep+.

**Files in this folder**
- `index.html` — the user-facing app
- `admin.html` — the admin dashboard (separate page, never linked from the user app)
- `config.js` — where you paste your Supabase keys and (optional) Tenor GIF/VAPID keys
- `style.css`, `shared.js` — shared design and logic, don't need editing
- `schema.sql` — creates all the database tables, security rules, and helper functions
- `sw.js` — service worker that receives Web Push notifications (optional feature, see below)
- `supabase/functions/send-push/` — edge function that sends Web Push notifications (optional feature, see below)

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

## Step 5 — (Optional but recommended) Get a free Tenor key for GIFs

1. Go to https://developers.google.com/tenor/guides/quickstart and follow
   the free API key steps (no credit card needed).
2. Paste the key into `config.js` as `TENOR_API_KEY`.
3. If you skip this, the app still works fine — the GIF button just shows
   a message saying GIFs aren't set up yet.

## Step 6 — Create your admin login

1. **Authentication → Users → Add user** — enter your email + password, leave Auto Confirm on.
2. **SQL Editor** → run (with your real email):
   ```sql
   insert into admin_allowlist (email) values ('you@example.com');
   ```
3. Open `admin.html` and log in.

## Step 7 — Test locally

```
python3 -m http.server 8080
```
Visit `http://localhost:8080`, register a test account (18+, phone number
made up is fine for local testing), finish your profile with a photo,
then register a *second* test account in a private/incognito window so
you have two people to chat between. Subscribe both (as admin, approve
the payment requests in `admin.html`), then message between them and try
sending a photo and a GIF.

## Step 8 — Publish

Same as prep+ — drag the folder onto **Netlify**, or push to **GitHub
Pages**, or **Vercel**. User link is the root URL; keep `/admin.html`
private (don't link to it from anywhere in the user app).

---

## Web Push Notifications (optional)

Lets users get notified of new messages (and status comments/likes) even
when new+ isn't open in a browser tab. Skip this section entirely if you
don't need it yet — everything else works fine without it, the push
toggle on the edit-profile screen just won't appear.

This has three pieces: a VAPID key pair (identifies your app to browsers'
push services), an edge function (`supabase/functions/send-push`) that
actually sends the notification using your Supabase **service_role** key,
and a **Database Webhook** that calls that function every time a new
message or notification is inserted.

### 1. Generate a VAPID key pair

You need Node.js installed locally for this one command:

```
npx web-push generate-vapid-keys
```

This prints a Public Key and a Private Key. Keep this terminal output —
you'll need both in the next two steps.

### 2. Add the public key to the app

Open `config.js` and replace `PASTE_YOUR_VAPID_PUBLIC_KEY` with the
Public Key from step 1.

### 3. Install the Supabase CLI and link your project

```
npm install -g supabase
supabase login
supabase link --project-ref YOUR_PROJECT_REF
```

Your project ref is the subdomain in your Supabase URL, e.g. for
`https://tgpqzphfmhactykxahqn.supabase.co` it's `tgpqzphfmhactykxahqn`.

### 4. Set the edge function's secrets

```
supabase secrets set VAPID_PUBLIC_KEY="paste the public key"
supabase secrets set VAPID_PRIVATE_KEY="paste the private key"
supabase secrets set VAPID_SUBJECT="mailto:you@example.com"
supabase secrets set PUSH_WEBHOOK_SECRET="make up a long random string"
```

`PUSH_WEBHOOK_SECRET` isn't from web-push — it's just a password you
invent, used in step 6 so only your own database can trigger a push
(otherwise anyone who found the function's URL could spam notifications
to your users).

### 5. Deploy the edge function

```
supabase functions deploy send-push --no-verify-jwt
```

`--no-verify-jwt` is required — Database Webhooks don't send a Supabase
user JWT, so the function needs to accept requests without one (it's
protected by `PUSH_WEBHOOK_SECRET` instead).

After deploying, copy the function's URL — the CLI prints it, or find it
under **Edge Functions** in the dashboard. It looks like
`https://YOUR_PROJECT_REF.functions.supabase.co/send-push`.

### 6. Create the Database Webhooks

In the Supabase dashboard: **Database → Webhooks → Create a new webhook**.
Create two of these (one per table):

**Webhook 1**
- Table: `messages`
- Events: `Insert`
- Type: `HTTP Request`, Method `POST`
- URL: the function URL from step 5
- HTTP Headers: add `x-webhook-secret` = the same random string from step 4

**Webhook 2** — identical, but Table: `notifications`.

### 7. Test it

Open new+ on two devices (or a private/incognito window for the second
account, like in Step 7). On device A: **My profile → Edit details**,
turn on "Push notifications on this device", allow the browser's
permission prompt. Then close or background the tab on device A and send
a message from device B — a notification should appear on device A
within a few seconds. Tapping it should open/focus new+.

If nothing arrives, check the edge function's logs (**Edge Functions →
send-push → Logs** in the dashboard) — the most common causes are a typo
in `PUSH_WEBHOOK_SECRET` (must match exactly between the webhook header
and the secret you set) or the browser permission being denied.

---

## Day to day

**Approving payments:** Payment requests tab, check your mobile money
statement, Approve. You'll hear a chime and see the browser tab flash
the moment someone taps "I've paid" — no need to keep refreshing.

**Managing users:** Users tab shows everyone, their subscription status,
and a Deactivate/Reactivate button — deactivating immediately logs them
out of new+ and blocks login until reactivated.

**PIN resets:** if a user forgets their PIN, they tap "Forgot PIN?" on
the login screen and enter their phone number — this doesn't need them to
be logged in. It shows up in **PIN resets** in `admin.html`. Verify it's
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
on profiles, and a few new functions. Just paste the whole `schema.sql`
into the SQL Editor and run it again — everything uses `create or
replace` / `if not exists` / `add column if not exists`, so nothing
existing gets touched or lost.

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
