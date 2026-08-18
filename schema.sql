-- ============================================================
-- new+ database schema
-- Run this in Supabase: Dashboard -> SQL Editor -> New query -> Run
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- PROFILES ----------
create table if not exists profiles (
  id uuid primary key default gen_random_uuid(),
  auth_uid uuid unique,
  phone text unique not null,
  pin_hash text not null,
  name text,
  dob date,
  district text,
  lat double precision,
  lng double precision,
  share_location boolean not null default false,
  avatar_path text,                        -- path inside the 'avatars' storage bucket
  profile_complete boolean not null default false,
  is_active boolean not null default true, -- admin can deactivate an account
  pin_must_change boolean not null default false, -- true right after an admin-approved PIN reset, until the user picks a new PIN
  subscription_status text not null default 'inactive'
      check (subscription_status in ('inactive','pending','active','expired')),
  subscription_expires_at timestamptz,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table profiles add column if not exists last_seen_at timestamptz not null default now();
alter table profiles add column if not exists pin_must_change boolean not null default false;
-- global mute: when true, this person gets no push notifications at all
-- (messages or otherwise), regardless of any other setting. Toggled by
-- long-pressing the bell icon on the directory page.
alter table profiles add column if not exists push_muted boolean not null default false;

-- ------------------------------------------------------------
-- PERFORMANCE FIX (scale to 1000+ concurrent users): get_directory()
-- (defined further down) filters on `is_active` and `profile_complete`
-- every time it runs — once per directory load, once per "load more"
-- page, for every user. Without an index covering that filter, Postgres
-- has to scan every row in `profiles` and check both columns on each one,
-- every single time. This partial index lets it jump straight to the
-- rows that actually qualify instead. It's a partial index (not a full
-- one) because most rows will match `is_active = true and
-- profile_complete = true`, so a small, targeted index is far cheaper
-- than a full one covering rows that never match anyway.
-- ------------------------------------------------------------
create index if not exists idx_profiles_active_complete
  on profiles (id)
  where is_active and profile_complete;

-- ---------- SUBSCRIPTION REQUESTS (manual mobile-money payments) ----------
create table if not exists subscription_requests (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  network text not null check (network in ('MTN','Airtel')),
  transaction_ref text,
  amount integer not null default 2000,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);
alter table subscription_requests alter column amount set default 2000;

-- Pesapal support: subscription_requests now covers two payment methods.
-- The original manual mobile-money flow still needs `network` and is
-- approved by hand in admin.html. Pesapal rows are auto-approved by the
-- pesapal-ipn Edge Function once Pesapal confirms payment, so `network`
-- isn't required for them.
alter table subscription_requests alter column network drop not null;
alter table subscription_requests add column if not exists payment_method text not null default 'manual' check (payment_method in ('manual','pesapal'));
alter table subscription_requests add column if not exists merchant_reference text unique;
alter table subscription_requests add column if not exists pesapal_tracking_id text;

-- pesapal-ipn looks up a row by pesapal_tracking_id on every single payment
-- confirmation call — index it so that lookup doesn't scan the whole table.
create index if not exists idx_subscription_requests_pesapal_tracking_id
  on subscription_requests (pesapal_tracking_id);

-- one pending request per user at a time (blocks duplicate "I've paid" taps at the DB level)
create unique index if not exists idx_one_pending_request_per_profile
  on subscription_requests (profile_id)
  where (status = 'pending');

-- ---------- CONVERSATIONS (always exactly one row per pair of users) ----------
create table if not exists conversations (
  id uuid primary key default gen_random_uuid(),
  user_a uuid not null references profiles(id) on delete cascade,
  user_b uuid not null references profiles(id) on delete cascade,
  last_message_at timestamptz not null default now(),
  last_read_a timestamptz not null default now(),
  last_read_b timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint chk_ordered_pair check (user_a < user_b) -- enforces a single canonical row per pair
);
create unique index if not exists idx_conversation_pair on conversations(user_a, user_b);
create index if not exists idx_conversations_a on conversations(user_a);
create index if not exists idx_conversations_b on conversations(user_b);
-- migrate existing deployments
alter table conversations add column if not exists last_read_a timestamptz not null default now();
alter table conversations add column if not exists last_read_b timestamptz not null default now();

-- ---------- MESSAGES ----------
create table if not exists messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id uuid not null references profiles(id) on delete cascade,
  kind text not null default 'text' check (kind in ('text','image','gif')),
  body text,           -- text content, or a GIF URL when kind = 'gif'
  image_path text,     -- path inside the 'chat-images' bucket when kind = 'image'
  reply_to_id uuid references messages(id) on delete set null,  -- message this one is replying to, if any
  created_at timestamptz not null default now()
);
-- migrate existing deployments
alter table messages add column if not exists reply_to_id uuid references messages(id) on delete set null;
create index if not exists idx_messages_conversation on messages(conversation_id, created_at);
alter table messages replica identity full;
-- migrate existing deployments: allow a 'voice' message kind (voice notes);
-- calling was tried and dropped, so 'call' is no longer a valid kind —
-- remove any leftover call-log messages first so the constraint below
-- doesn't reject them
delete from messages where kind = 'call';
alter table messages drop constraint if exists messages_kind_check;
alter table messages add constraint messages_kind_check check (kind in ('text','image','gif','voice'));

-- migrate existing deployments: track when a message was last edited
alter table messages add column if not exists edited_at timestamptz;

-- the 'gif' kind stored a raw URL in `body`, which the client rendered into
-- an HTML attribute (src="...") — an attacker-controlled body could break
-- out of that attribute and inject a stored-XSS payload. GIFs were dropped
-- from the product, so remove the kind entirely and close the hole.
delete from messages where kind = 'gif';
alter table messages drop constraint if exists messages_kind_check;
alter table messages add constraint messages_kind_check check (kind in ('text','image','voice'));

-- calling (audio/video) was tried and dropped in favor of voice notes —
-- drop its table if an earlier deployment created it
drop table if exists calls cascade;

-- a per-user "delete for me" marker: the message row stays intact (the
-- other participant still sees it) but is hidden from whichever profile
-- has a row here for it
create table if not exists message_hides (
  message_id uuid not null references messages(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (message_id, profile_id)
);

-- ---------- ADS (admin-managed banner ads) ----------
create table if not exists ads (
  id uuid primary key default gen_random_uuid(),
  message text,                  -- short text shown in the banner
  image_path text,               -- path inside the 'ads' storage bucket (optional, unused by text-only ads)
  link_url text,                 -- where a tap takes the user (optional)
  placement text not null default 'directory_top',
  is_active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists idx_ads_placement on ads(placement, is_active);
-- migrate existing deployments: make sure the columns exist / image is optional
alter table ads add column if not exists message text;
alter table ads alter column image_path drop not null;
-- backstop for the http(s)-only check already done in admin.html: this is
-- rendered straight into an <a href> for every visitor, so even though only
-- admin can write it, a non-http(s) scheme (e.g. javascript:) should never
-- be storable in the first place, not just filtered client-side
alter table ads drop constraint if exists ads_link_url_scheme;
alter table ads add constraint ads_link_url_scheme check (link_url is null or link_url ~* '^https?://');

-- ---------- ADMIN ALLOWLIST ----------
create table if not exists admin_allowlist (
  email text primary key
);

-- ---------- LOGIN ATTEMPT THROTTLING ----------
-- Tracks failed login_with_pin attempts per phone number so a 4-digit PIN
-- can't be brute-forced (only 10,000 possible values). After 5 failures the
-- phone is locked out for a growing cooldown (doubling each extra failure,
-- capped at 60 minutes); a correct login clears the row.
create table if not exists login_attempts (
  phone text primary key,
  fail_count int not null default 0,
  locked_until timestamptz,
  last_attempt_at timestamptz not null default now()
);
-- No client (anon/authenticated) should ever read or write this table
-- directly — it's only touched by login_with_pin() (security definer, so
-- it bypasses RLS the same way the other helper functions do). Without RLS
-- enabled here, every phone number that has ever had a failed login
-- attempt — plus its lockout state — would be readable by anyone with the
-- public anon key. No policies are created below on purpose: RLS enabled
-- with zero policies means default-deny for every direct client request.
alter table login_attempts enable row level security;

-- ---------- PIN RESET REQUEST THROTTLING ----------
-- request_pin_reset() tells the caller outright whether a phone number is
-- registered (phone_not_found vs ok) — that's needed so a genuine user
-- knows to try registering instead, but without a limit it also lets
-- anyone script through phone numbers to find out which ones are on
-- newplus. This caps it at 5 requests per phone per hour, independent of
-- whether each one succeeds or fails.
create table if not exists pin_reset_attempts (
  phone text primary key,
  request_count int not null default 0,
  window_started_at timestamptz not null default now()
);
-- Same reasoning as login_attempts: no direct client access, only touched
-- by request_pin_reset() via security definer.
alter table pin_reset_attempts enable row level security;

-- ---------- PIN RESET REQUESTS ----------
-- Same manual-approval shape as subscription_requests: a user who forgot
-- their PIN can't log in to prove who they are, so this has to be a public
-- (session-only) RPC rather than a normal "own row" insert. An admin
-- verifies the person some other way they trust (phone call, knowing the
-- user, etc — same as verifying a mobile-money payment) and approves,
-- which sets a temporary PIN the admin then relays to the user manually.
create table if not exists pin_reset_requests (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  phone text not null,
  submitted_dob date,        -- what the requester typed, for admin to compare to the real dob
  submitted_district text,   -- what the requester typed, for admin to compare to the real district
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);
-- migrate existing deployments: verification questions on the forgot-PIN form
alter table pin_reset_requests add column if not exists submitted_dob date;
alter table pin_reset_requests add column if not exists submitted_district text;
-- one pending reset request per profile at a time
create unique index if not exists idx_one_pending_reset_per_profile
  on pin_reset_requests (profile_id)
  where (status = 'pending');
create index if not exists idx_pin_reset_requests_status on pin_reset_requests(status, created_at);

-- ---------- WEB PUSH SUBSCRIPTIONS ----------
-- One row per browser/device a user has enabled push notifications on
-- (a person using the app on two phones gets two rows). Never read or
-- written by this schema itself — a separate edge function (service-role,
-- so it bypasses RLS) reads these to actually send a push when a new
-- message or notification is inserted. See SETUP_GUIDE.md for the
-- edge function + database webhook wiring this depends on.
create table if not exists push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_push_subscriptions_profile on push_subscriptions(profile_id);

-- ---------- PRIVATE LOCATION STORAGE ----------
-- Raw coordinates used to live directly on `profiles`, a table that (a) is
-- broadcast wholesale to every subscriber over Realtime for the live
-- directory, and (b) any other complete/active profile's row can be read by
-- any active subscriber. Both of those meant precise lat/lng for every user
-- was reachable directly, which is enough for a few fake accounts at known
-- coordinates to triangulate someone's real location. Coordinates now live
-- only here, a table only the owner (or admin) can ever read, is never
-- added to the realtime publication, and the only way anyone else learns
-- anything from it is the coarse distance bucket get_directory() returns.
-- (RLS policy + data migration for this table are set up further down,
-- after is_admin()/my_profile_id() exist — see the Row Level Security section.)
create table if not exists profile_locations (
  profile_id uuid primary key references profiles(id) on delete cascade,
  lat double precision,
  lng double precision
);

-- ---------- STATUSES (text/photo updates that auto-expire after 24h) ----------
create table if not exists statuses (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  text_content text,
  image_path text,      -- path inside the 'statuses' storage bucket
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  constraint statuses_has_content check (text_content is not null or image_path is not null)
);
create index if not exists idx_statuses_profile on statuses(profile_id, created_at);
create index if not exists idx_statuses_expires on statuses(expires_at);

-- (removed) "viewed by" tracking on statuses — replaced by comments below.
-- Drops are safe to re-run even if this table/functions were never created.
drop function if exists get_status_viewers(uuid);
drop function if exists mark_status_viewed(uuid);
drop table if exists status_views;

-- comments on a status/post
create table if not exists status_comments (
  id uuid primary key default gen_random_uuid(),
  status_id uuid not null references statuses(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  comment_text text not null,
  created_at timestamptz not null default now(),
  constraint status_comments_not_blank check (length(trim(comment_text)) > 0),
  constraint status_comments_max_length check (length(comment_text) <= 4000)
);
create index if not exists idx_status_comments_status on status_comments(status_id, created_at);

-- lets the post owner (or another commenter) reply directly to a specific
-- comment instead of just adding another flat entry to the list
alter table status_comments add column if not exists reply_to_id uuid references status_comments(id) on delete set null;
create index if not exists idx_status_comments_reply_to on status_comments(reply_to_id);

-- likes on a status/post — one row per (status, profile), so liking twice
-- is just a no-op conflict and unliking is a plain delete
create table if not exists status_likes (
  status_id uuid not null references statuses(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (status_id, profile_id)
);
create index if not exists idx_status_likes_status on status_likes(status_id);

-- status_views: tracks which statuses the CURRENT VIEWER has personally
-- seen, so their own device can dim that person's ring once they've
-- watched everything. This is deliberately NOT a "viewed by" list — unlike
-- the one removed earlier, nobody (not even the status owner) can query who
-- else has seen a status; each viewer can only read/write their own rows.
create table if not exists status_views (
  status_id uuid not null references statuses(id) on delete cascade,
  viewer_id uuid not null references profiles(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (status_id, viewer_id)
);
create index if not exists idx_status_views_viewer on status_views(viewer_id);

-- notifications — created automatically by triggers below (never inserted
-- directly by clients): a reply to your comment, a top-level comment on
-- your post, or a like on your post.
create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,  -- who receives it
  actor_id uuid not null references profiles(id) on delete cascade,    -- who triggered it
  type text not null default 'comment_reply' check (type in ('comment_reply','status_comment','status_like')),
  status_id uuid references statuses(id) on delete cascade,
  comment_id uuid references status_comments(id) on delete cascade,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_notifications_profile on notifications(profile_id, created_at desc);
-- migrate existing deployments: widen the type check to add the two new kinds
alter table notifications drop constraint if exists notifications_type_check;
alter table notifications add constraint notifications_type_check check (type in ('comment_reply','status_comment','status_like'));

-- storage buckets
-- file_size_limit (bytes) and allowed_mime_types are enforced by Supabase
-- Storage itself on every upload, regardless of what the client claims —
-- the app already re-encodes photos to JPEG client-side and only ever
-- sends image/jpeg or image/mpeg-family audio, so these limits just make
-- that the actual server-side rule instead of a convention the client
-- could be bypassed to ignore. on conflict does update so re-running this
-- file also tightens limits on buckets that already existed.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-images', 'chat-images', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ads', 'ads', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('statuses', 'statuses', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('voice-notes', 'voice-notes', false, 10485760, array['audio/mpeg','audio/webm','audio/mp4','audio/x-m4a','audio/m4a'])
on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- ============================================================
-- Push notification triggers (direct pg_net, bypasses the
-- dashboard Webhooks UI in case the project's internal
-- supabase_functions schema is broken — this only depends on
-- pg_net, which is a standard extension).
--
-- Calls the deployed `send-push` edge function whenever a new
-- message or notification is inserted.
-- ============================================================
create or replace function notify_send_push()
returns trigger
language plpgsql
security definer
as $$
declare
  recipient_id uuid;
  recipient_muted boolean := false;
begin
  -- Figure out who the recipient is, so we can check their global mute
  -- setting before bothering to send a push at all.
  if TG_TABLE_NAME = 'messages' then
    select case
      when user_a = NEW.sender_id then user_b
      when user_b = NEW.sender_id then user_a
    end into recipient_id
    from conversations where id = NEW.conversation_id;
  elsif TG_TABLE_NAME = 'notifications' then
    recipient_id := NEW.profile_id;
  end if;

  if recipient_id is not null then
    select push_muted into recipient_muted from profiles where id = recipient_id;
    if recipient_muted then
      return NEW;
    end if;
  end if;

  perform net.http_post(
    url := 'https://tgpqzphfmhactykxahqn.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer sb_publishable_QTUByYlNoDQ8RoJ_usnAJw_p3VAVwLt'
    ),
    body := jsonb_build_object(
      'type', 'INSERT',
      'table', TG_TABLE_NAME,
      'record', to_jsonb(NEW)
    )
  );
  return NEW;
end;
$$;

drop trigger if exists on_message_send_push on messages;
create trigger on_message_send_push
  after insert on messages
  for each row execute function notify_send_push();

drop trigger if exists on_notification_send_push on notifications;
create trigger on_notification_send_push
  after insert on notifications
  for each row execute function notify_send_push();

-- ============================================================
-- Helpers
-- ============================================================
create or replace function is_admin()
returns boolean
language sql security definer stable
as $$
  select exists (select 1 from admin_allowlist a where a.email = (auth.jwt() ->> 'email'));
$$;
grant execute on function is_admin() to anon, authenticated;

create or replace function my_profile_id()
returns uuid
language sql security definer stable
as $$
  select id from profiles where auth_uid = auth.uid();
$$;
grant execute on function my_profile_id() to anon, authenticated;

create or replace function is_active_subscriber()
returns boolean
language sql security definer stable
as $$
  -- This is the REAL, enforced check — the database never trusts the app's
  -- own display logic. Change "true" back to "false" only if you want to
  -- let every active account browse/chat for free again (matching
  -- SUBSCRIPTION_REQUIRED = false in index.html).
  select case when true then (
    exists (
      select 1 from profiles p
      where p.auth_uid = auth.uid()
        and p.subscription_status = 'active'
        and p.is_active
        and (p.subscription_expires_at is null or p.subscription_expires_at > now())
    )
  ) else (
    exists (
      select 1 from profiles p where p.auth_uid = auth.uid() and p.is_active
    )
  ) end;
$$;
grant execute on function is_active_subscriber() to anon, authenticated;

-- profile_is_active: lets a policy check whether SOME OTHER profile is
-- currently active, without needing direct SELECT access to the profiles
-- table (regular users can only read their own row there — see
-- profiles_select_own_or_admin below). security definer bypasses that for
-- this one narrow boolean check only.
create or replace function profile_is_active(p_id uuid)
returns boolean
language sql security definer stable
as $$
  select coalesce((select p.is_active from profiles p where p.id = p_id), false);
$$;
grant execute on function profile_is_active(uuid) to anon, authenticated;

-- Bypass RLS (via security definer) to look up a reply's parent comment's
-- status — used by status_comments_insert_own below. A policy on
-- status_comments cannot safely query status_comments directly (Postgres
-- reports "infinite recursion detected in policy"), so this self-referential
-- lookup has to go through a function instead.
create or replace function status_comment_parent_status(p_comment_id uuid)
returns uuid
language sql security definer stable
as $$
  select status_id from status_comments where id = p_comment_id;
$$;
grant execute on function status_comment_parent_status(uuid) to anon, authenticated;

-- Automatically notify people about activity on a status/post:
--  - reply to your comment -> notifies the comment's author ('comment_reply')
--  - a top-level comment on your post -> notifies the post owner ('status_comment')
-- Never notifies someone about their own activity. If a reply lands on
-- your own comment on your own post, only one notification is sent (no
-- double-up). Runs as the function owner (security definer), so it can
-- write to `notifications` regardless of the inserting user's own RLS
-- access to that table — same pattern as the helper functions above.
create or replace function notify_comment_reply()
returns trigger
language plpgsql security definer
as $$
declare
  v_parent_profile uuid;
  v_post_owner uuid;
begin
  if new.reply_to_id is not null then
    select profile_id into v_parent_profile from status_comments where id = new.reply_to_id;
    if v_parent_profile is not null and v_parent_profile <> new.profile_id then
      insert into notifications (profile_id, actor_id, type, status_id, comment_id)
      values (v_parent_profile, new.profile_id, 'comment_reply', new.status_id, new.id);
    end if;
  else
    select profile_id into v_post_owner from statuses where id = new.status_id;
    if v_post_owner is not null and v_post_owner <> new.profile_id then
      insert into notifications (profile_id, actor_id, type, status_id, comment_id)
      values (v_post_owner, new.profile_id, 'status_comment', new.status_id, new.id);
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_notify_comment_reply on status_comments;
create trigger trg_notify_comment_reply
  after insert on status_comments
  for each row execute function notify_comment_reply();

-- Notify the post owner when someone likes their post (skip self-likes).
create or replace function notify_status_like()
returns trigger
language plpgsql security definer
as $$
declare
  v_post_owner uuid;
begin
  select profile_id into v_post_owner from statuses where id = new.status_id;
  if v_post_owner is not null and v_post_owner <> new.profile_id then
    insert into notifications (profile_id, actor_id, type, status_id)
    values (v_post_owner, new.profile_id, 'status_like', new.status_id);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_notify_status_like on status_likes;
create trigger trg_notify_status_like
  after insert on status_likes
  for each row execute function notify_status_like();

-- ============================================================
-- Private location storage (profile_locations): RLS + one-time migration.
-- Must come after is_admin()/my_profile_id() above, which the policy uses.
-- ============================================================
alter table profile_locations enable row level security;
drop policy if exists "profile_locations_own_or_admin" on profile_locations;
create policy "profile_locations_own_or_admin" on profile_locations for all
  using (profile_id = my_profile_id() or is_admin())
  with check (profile_id = my_profile_id() or is_admin());

-- one-time migration: carry over anyone's existing coordinates, then wipe
-- them from `profiles` — leaving them in place would still leak full
-- precision to every subscriber via the realtime channel even after the
-- app switches to the bucketed RPC below.
insert into profile_locations (profile_id, lat, lng)
select id, lat, lng from profiles where lat is not null and lng is not null
on conflict (profile_id) do update set lat = excluded.lat, lng = excluded.lng;
update profiles set lat = null, lng = null where lat is not null or lng is not null;
-- profiles.lat / profiles.lng are kept (unused, always null) rather than
-- dropped, so this script stays safe to re-run without an ALTER ... DROP.

-- Lets the signed-in user read back their OWN coordinates (e.g. to pre-fill
-- the "share my location" toggle on the edit-profile screen). Never
-- returns anyone else's — enforced by filtering on auth.uid() itself, not
-- just by RLS, since this is security definer.
create or replace function get_my_location()
returns table(lat double precision, lng double precision, share_location boolean)
language sql security definer stable
as $$
  select pl.lat, pl.lng, p.share_location
  from profiles p
  left join profile_locations pl on pl.profile_id = p.id
  where p.auth_uid = auth.uid();
$$;
grant execute on function get_my_location() to anon, authenticated;

-- The directory: returns a coarse distance bucket instead of a raw number,
-- and computes it entirely server-side so no caller ever receives another
-- user's coordinates (or even their own exact distance) in the response.
--
-- PAGINATION UPDATE: this used to hand back everything in one go (later
-- capped at a flat 1000). It now takes a page size (p_limit) and how many
-- rows to skip (p_offset), like turning pages — call it once with no
-- arguments to get the first 200 people, then again with p_offset=200 for
-- the next 200, and so on. p_limit is clamped to 200 server-side (not just
-- trusted from the caller) so a direct RPC call can't request a huge page
-- and defeat the point of paging.
drop function if exists get_directory();
create or replace function get_directory(p_limit integer default 200, p_offset integer default 0)
returns table(
  id uuid, name text, dob date, district text, avatar_path text,
  last_seen_at timestamptz, distance_label text
)
language plpgsql security definer
as $$
declare
  my_id uuid := my_profile_id();
  my_district text;
  me_lat double precision;
  me_lng double precision;
  safe_limit integer := least(greatest(coalesce(p_limit, 200), 1), 200);
  safe_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if my_id is null then raise exception 'no matching profile'; end if;
  if not is_active_subscriber() then
    return; -- empty result set: this is the actual paywall for the directory
  end if;

  select p.district into my_district from profiles p where p.id = my_id;
  select lat, lng into me_lat, me_lng from profile_locations where profile_id = my_id;

  return query
  with dists as (
    select
      p.id, p.name, p.dob, p.district, p.avatar_path, p.last_seen_at,
      case when me_lat is null or pl.lat is null then null else
        2 * 6371 * asin(sqrt(
          sin(radians(pl.lat - me_lat) / 2) ^ 2 +
          cos(radians(me_lat)) * cos(radians(pl.lat)) * sin(radians(pl.lng - me_lng) / 2) ^ 2
        ))
      end as d_km
    from profiles p
    left join profile_locations pl on pl.profile_id = p.id
    where p.id <> my_id and p.profile_complete and p.is_active
  )
  select
    dists.id, dists.name, dists.dob, dists.district, dists.avatar_path, dists.last_seen_at,
    case
      when dists.d_km is null then null
      when dists.d_km < 1 then 'Less than 1 km away'
      when dists.d_km < 3 then '1–3 km away'
      when dists.d_km < 5 then '3–5 km away'
      when dists.d_km < 10 then '5–10 km away'
      when dists.d_km < 25 then '10–25 km away'
      when dists.d_km < 50 then '25–50 km away'
      else '50+ km away'
    end as distance_label
  from dists
  order by (dists.d_km is null) asc, dists.d_km asc, (dists.district = my_district) desc, dists.name asc
  limit safe_limit offset safe_offset;
end;
$$;
grant execute on function get_directory(integer, integer) to anon, authenticated;

-- get_public_profiles: the ONLY way a client can look up another user's
-- name/photo/last-seen (for chat headers, chat lists, status avatars,
-- sender-name lookups, etc). Deliberately never selects phone or pin_hash —
-- those must never leave the database for anyone but the row's own owner or
-- an admin. Same visibility rule as the old table-level policy (own row,
-- admin, or a completed/active profile while the caller is an active
-- subscriber) but enforced here instead of on the table, so the table
-- itself no longer has to grant blanket row access to other users.
create or replace function get_public_profiles(p_ids uuid[])
returns table(
  id uuid, name text, dob date, district text, avatar_path text, last_seen_at timestamptz
)
language sql security definer stable
as $$
  select p.id, p.name, p.dob, p.district, p.avatar_path, p.last_seen_at
  from profiles p
  where p.id = any(p_ids)
    and (
      p.auth_uid = auth.uid()
      or is_admin()
      or (p.profile_complete and p.is_active and is_active_subscriber())
    );
$$;
grant execute on function get_public_profiles(uuid[]) to anon, authenticated;

-- get_my_notifications: the ONLY way a client reads its own notifications
-- with the actor's name/photo attached. A plain client-side select with an
-- embedded `actor:actor_id(name, avatar_path)` join hits the profiles RLS
-- policy (own row only), so it silently returns null for every notification
-- whose actor isn't you — hence "Someone" / a "?" avatar on every row. This
-- function runs as security definer to read just name/avatar_path for the
-- actor, same restricted shape as get_public_profiles, and only ever for
-- notifications belonging to the caller.
create or replace function get_my_notifications()
returns table(
  id uuid, type text, status_id uuid, comment_id uuid, read_at timestamptz,
  created_at timestamptz, actor_name text, actor_avatar_path text
)
language sql security definer stable
as $$
  select n.id, n.type, n.status_id, n.comment_id, n.read_at, n.created_at,
         p.name, p.avatar_path
  from notifications n
  join profiles p on p.id = n.actor_id
  where n.profile_id = my_profile_id()
  order by n.created_at desc
  limit 100;
$$;
grant execute on function get_my_notifications() to anon, authenticated;

-- get_status_comments: the ONLY way a client reads a status's comments with
-- the commenter's name/photo attached. A plain client-side select with an
-- embedded `profiles:profile_id(name, avatar_path)` join hits the profiles
-- RLS policy (own row only), so it silently returns null for every
-- commenter who isn't you — hence "Someone" on every comment that isn't
-- your own. This function runs as security definer to read just
-- name/avatar_path for each commenter, same restricted shape as
-- get_public_profiles, and enforces the exact same visibility rule as the
-- status_comments_select_if_status_visible policy: you can only pull
-- comments for a status you're actually allowed to see (your own, admin,
-- or an unexpired status while you're an active subscriber).
create or replace function get_status_comments(p_status_id uuid)
returns table(
  id uuid, comment_text text, created_at timestamptz, profile_id uuid,
  reply_to_id uuid, commenter_name text, commenter_avatar_path text
)
language sql security definer stable
as $$
  select c.id, c.comment_text, c.created_at, c.profile_id, c.reply_to_id,
         p.name, p.avatar_path
  from status_comments c
  join profiles p on p.id = c.profile_id
  where c.status_id = p_status_id
    and (
      is_admin()
      or exists (
        select 1 from statuses s
        where s.id = p_status_id
          and (
            s.profile_id = my_profile_id()
            or is_admin()
            or (s.expires_at > now() and is_active_subscriber())
          )
      )
    )
  order by c.created_at asc;
$$;
grant execute on function get_status_comments(uuid) to anon, authenticated;

-- ============================================================
-- PIN hashing (bcrypt, via pgcrypto)
-- ------------------------------------------------------------
-- PINs used to be hashed with plain sha256 — fast to compute, which is
-- exactly the wrong property for a secret with only 10,000 possible
-- values (0000-9999): if the pin_hash column were ever exposed, all
-- 10,000 sha256 hashes can be precomputed and matched in a fraction of
-- a second. bcrypt is deliberately slow, so the same brute force takes
-- real minutes per account instead.
--
-- verify_pin() still recognizes the old sha256 format (a 64-char hex
-- string never starts with bcrypt's "$2" prefix) so existing accounts'
-- PINs keep working without a bulk migration — login_with_pin below
-- upgrades a matched old-format hash to bcrypt in place, on the spot,
-- so every account quietly moves to the new format the next time its
-- owner logs in.
-- ============================================================
create or replace function hash_pin(p_pin text)
returns text
language sql
as $$
  select crypt(p_pin, gen_salt('bf'));
$$;

create or replace function verify_pin(p_stored_hash text, p_candidate_pin text)
returns boolean
language sql
as $$
  select case
    when p_stored_hash like '$2%' then p_stored_hash = crypt(p_candidate_pin, p_stored_hash)
    else p_stored_hash = encode(digest(p_candidate_pin, 'sha256'), 'hex')
  end;
$$;

-- ============================================================
-- Registration and login (phone + PIN, no OTP, same pattern as prep+)
-- ============================================================
-- must drop first: Postgres won't let create-or-replace change a
-- function's return type, and this version returns jsonb (with
-- pin_hash and phone stripped out — the client never reads either,
-- no reason for them to ever leave the database) instead of the raw
-- profiles row
drop function if exists register_with_pin(text, text, date, text);
create or replace function register_with_pin(p_phone text, p_pin text, p_dob date, p_district text)
returns jsonb
language plpgsql security definer
as $$
declare
  new_row profiles;
begin
  if auth.uid() is null then raise exception 'no active session'; end if;
  if exists (select 1 from profiles where phone = p_phone) then raise exception 'phone_taken'; end if;
  -- server-side age gate: the client also checks this, but a direct RPC
  -- call must never be able to bypass the 18+ requirement
  if p_dob is null or p_dob > (current_date - interval '18 years') then
    raise exception 'must_be_18';
  end if;
  insert into profiles (auth_uid, phone, pin_hash, dob, district)
  values (auth.uid(), p_phone, hash_pin(p_pin), p_dob, p_district)
  returning * into new_row;
  return to_jsonb(new_row) - 'pin_hash' - 'phone';
end;
$$;
grant execute on function register_with_pin(text, text, date, text) to anon, authenticated;

-- must drop first: Postgres won't let create-or-replace change a
-- function's return type, and this version returns jsonb instead of
-- profiles (see comment inside the function for why)
drop function if exists login_with_pin(text, text);
create or replace function login_with_pin(p_phone text, p_pin text)
returns jsonb
language plpgsql security definer
as $$
declare
  match_row profiles;
  attempt login_attempts;
  new_fail_count int;
  lock_minutes numeric;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'no_active_session');
  end if;

  select * into attempt from login_attempts where phone = p_phone;
  if attempt.locked_until is not null and attempt.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'too_many_attempts');
  end if;

  select * into match_row from profiles where phone = p_phone;
  if match_row is null or not verify_pin(match_row.pin_hash, p_pin) then
    -- IMPORTANT: this branch must not RAISE. A raised exception aborts and
    -- rolls back the whole transaction for this RPC call, which would undo
    -- the insert below and silently erase every failed attempt — which is
    -- exactly the bug that made the lockout never trigger. Returning a
    -- plain value instead lets this write actually commit.
    new_fail_count := coalesce(attempt.fail_count, 0) + 1;
    lock_minutes := case when new_fail_count >= 5 then least(power(2, new_fail_count - 4), 60) else null end;
    insert into login_attempts (phone, fail_count, locked_until, last_attempt_at)
    values (
      p_phone, new_fail_count,
      case when lock_minutes is not null then now() + (lock_minutes * interval '1 minute') else null end,
      now()
    )
    on conflict (phone) do update set
      fail_count = excluded.fail_count,
      locked_until = excluded.locked_until,
      last_attempt_at = excluded.last_attempt_at;
    return jsonb_build_object('ok', false, 'error', 'invalid_credentials');
  end if;

  if not match_row.is_active then
    return jsonb_build_object('ok', false, 'error', 'account_deactivated');
  end if;

  delete from login_attempts where phone = p_phone;
  -- a correct login is proof of the real PIN, so this is also the natural
  -- moment to quietly move an old-format hash onto bcrypt — no separate
  -- migration step needed, every account upgrades itself the next time
  -- its owner logs in
  update profiles
    set auth_uid = auth.uid(),
        pin_hash = case when match_row.pin_hash like '$2%' then match_row.pin_hash else hash_pin(p_pin) end
    where id = match_row.id
    returning * into match_row;
  return jsonb_build_object('ok', true, 'profile', to_jsonb(match_row) - 'pin_hash' - 'phone');
end;
$$;
grant execute on function login_with_pin(text, text) to anon, authenticated;

-- ============================================================
-- Complete profile (name, bio-free intro not included yet, avatar,
-- optional lat/lng) -- required before a user appears in the directory
-- ============================================================
create or replace function complete_profile(p_name text, p_avatar_path text, p_lat double precision, p_lng double precision, p_share_location boolean)
returns profiles
language plpgsql security definer
as $$
declare
  updated profiles;
  my_id uuid;
begin
  select id into my_id from profiles where auth_uid = auth.uid();
  if my_id is null then raise exception 'no matching profile'; end if;

  update profiles set
    name = p_name,
    avatar_path = coalesce(p_avatar_path, avatar_path),
    share_location = p_share_location,
    profile_complete = true
  where id = my_id
  returning * into updated;

  -- coordinates go to the private table, never back onto `profiles`
  if p_share_location and p_lat is not null and p_lng is not null then
    insert into profile_locations (profile_id, lat, lng) values (my_id, p_lat, p_lng)
    on conflict (profile_id) do update set lat = excluded.lat, lng = excluded.lng;
  else
    delete from profile_locations where profile_id = my_id;
  end if;

  return updated;
end;
$$;
grant execute on function complete_profile(text, text, double precision, double precision, boolean) to anon, authenticated;

-- Avatar-only update, so the client never has to re-supply (or, worse,
-- guess at) the user's current coordinates just to change a photo.
create or replace function update_avatar(p_avatar_path text)
returns profiles
language plpgsql security definer
as $$
declare
  updated profiles;
begin
  update profiles set avatar_path = p_avatar_path
  where auth_uid = auth.uid()
  returning * into updated;
  if updated is null then raise exception 'no matching profile'; end if;
  return updated;
end;
$$;
grant execute on function update_avatar(text) to anon, authenticated;

-- ============================================================
-- Update profile details (name, date of birth, district, location)
-- Lets an existing user edit their own info from "My profile" —
-- separate from complete_profile so avatar-only updates and initial
-- signup aren't affected.
-- ============================================================
create or replace function update_profile_details(p_name text, p_dob date, p_district text, p_lat double precision, p_lng double precision, p_share_location boolean)
returns profiles
language plpgsql security definer
as $$
declare
  updated profiles;
  my_id uuid;
begin
  if p_dob is null or p_dob > (current_date - interval '18 years') then
    raise exception 'must_be_18';
  end if;

  select id into my_id from profiles where auth_uid = auth.uid();
  if my_id is null then raise exception 'no matching profile'; end if;

  update profiles set
    name = p_name,
    dob = p_dob,
    district = p_district,
    share_location = p_share_location
  where id = my_id
  returning * into updated;

  if p_share_location and p_lat is not null and p_lng is not null then
    insert into profile_locations (profile_id, lat, lng) values (my_id, p_lat, p_lng)
    on conflict (profile_id) do update set lat = excluded.lat, lng = excluded.lng;
  else
    delete from profile_locations where profile_id = my_id;
  end if;

  return updated;
end;
$$;
grant execute on function update_profile_details(text, date, text, double precision, double precision, boolean) to anon, authenticated;

-- ============================================================
-- Change PIN — requires the current PIN to be entered correctly first.
-- Uses the same hashing scheme as registration/login for now.
-- ============================================================
create or replace function change_pin(p_current_pin text, p_new_pin text)
returns void
language plpgsql security definer
as $$
declare
  me profiles;
begin
  select * into me from profiles where auth_uid = auth.uid();
  if me is null then raise exception 'no matching profile'; end if;
  if not verify_pin(me.pin_hash, p_current_pin) then
    raise exception 'invalid_credentials';
  end if;
  update profiles set pin_hash = hash_pin(p_new_pin), pin_must_change = false where id = me.id;
end;
$$;
grant execute on function change_pin(text, text) to anon, authenticated;

-- ============================================================
-- Forgot PIN — request, admin approve/reject, and the forced
-- new-PIN screen the user gets after logging in with a temp PIN.
-- ============================================================

-- Called from the "Forgot PIN?" screen. No login required (that's the
-- whole point) — just an anonymous session, same as register/login.
-- migrate existing deployments: the old (text)-only signature is being
-- replaced by (text, date, text) below — drop it first so calls with one
-- argument don't stay pinned to the old version instead of picking up
-- defaults on the new one
drop function if exists request_pin_reset(text);

create or replace function request_pin_reset(p_phone text, p_dob date default null, p_district text default null)
returns jsonb
language plpgsql security definer
as $$
declare
  target profiles;
  attempt pin_reset_attempts;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'no_active_session');
  end if;

  -- throttle: 5 requests per phone number per rolling hour, checked before
  -- the phone_not_found lookup below so enumeration is capped either way
  select * into attempt from pin_reset_attempts where phone = p_phone;
  if attempt.window_started_at is not null and attempt.window_started_at > now() - interval '1 hour' and attempt.request_count >= 5 then
    return jsonb_build_object('ok', false, 'error', 'too_many_attempts');
  end if;
  insert into pin_reset_attempts (phone, request_count, window_started_at)
  values (p_phone, 1, now())
  on conflict (phone) do update set
    request_count = case when pin_reset_attempts.window_started_at > now() - interval '1 hour' then pin_reset_attempts.request_count + 1 else 1 end,
    window_started_at = case when pin_reset_attempts.window_started_at > now() - interval '1 hour' then pin_reset_attempts.window_started_at else now() end;

  select * into target from profiles where phone = p_phone;
  if target is null then
    return jsonb_build_object('ok', false, 'error', 'phone_not_found');
  end if;
  if not target.is_active then
    return jsonb_build_object('ok', false, 'error', 'account_deactivated');
  end if;

  -- p_dob/p_district are exactly what the requester typed, stored as-is
  -- (even if wrong) so the admin can see a submitted-vs-actual mismatch
  -- instead of a silent rejection — a wrong answer is itself a useful
  -- signal, not something to block on here.
  -- idempotent: if one's already pending, refresh their answers instead of erroring
  if exists (select 1 from pin_reset_requests where profile_id = target.id and status = 'pending') then
    update pin_reset_requests
      set submitted_dob = p_dob, submitted_district = p_district, created_at = now()
      where profile_id = target.id and status = 'pending';
  else
    insert into pin_reset_requests (profile_id, phone, submitted_dob, submitted_district)
      values (target.id, p_phone, p_dob, p_district);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function request_pin_reset(text, date, text) to anon, authenticated;

-- Admin approves a reset: sets a temporary PIN (generated client-side by
-- admin.html and shown on screen for the admin to relay to the user
-- themselves — phone call, WhatsApp, in person — same manual-contact
-- pattern as approving a mobile-money payment) and flags the account so
-- the user is forced to pick their own new PIN on next login.
create or replace function admin_set_temp_pin(p_request_id uuid, p_temp_pin text)
returns void
language plpgsql security definer
as $$
declare
  req pin_reset_requests;
begin
  if not is_admin() then raise exception 'not_authorized'; end if;
  if not (p_temp_pin ~ '^\d{4}$') then raise exception 'invalid_pin_format'; end if;

  select * into req from pin_reset_requests where id = p_request_id and status = 'pending';
  if req is null then raise exception 'request_not_found'; end if;

  update profiles
    set pin_hash = hash_pin(p_temp_pin),
        pin_must_change = true
    where id = req.profile_id;

  update pin_reset_requests set status = 'approved' where id = p_request_id;
end;
$$;
grant execute on function admin_set_temp_pin(uuid, text) to authenticated;

-- Called once, right after the user logs in with the temp PIN — no need
-- to re-enter it, since successfully logging in already proved they have
-- it. Only works while pin_must_change is actually set.
create or replace function set_new_pin_after_reset(p_new_pin text)
returns void
language plpgsql security definer
as $$
declare
  me profiles;
begin
  select * into me from profiles where auth_uid = auth.uid();
  if me is null then raise exception 'no matching profile'; end if;
  if not me.pin_must_change then raise exception 'no_reset_pending'; end if;
  if not (p_new_pin ~ '^\d{4}$') then raise exception 'invalid_pin_format'; end if;
  update profiles set pin_hash = hash_pin(p_new_pin), pin_must_change = false where id = me.id;
end;
$$;
grant execute on function set_new_pin_after_reset(text) to anon, authenticated;

-- ============================================================
-- Conversations & messaging
-- ============================================================
create or replace function get_or_create_conversation(p_other_profile_id uuid)
returns conversations
language plpgsql security definer
as $$
declare
  me uuid;
  a uuid;
  b uuid;
  convo conversations;
begin
  select id into me from profiles where auth_uid = auth.uid();
  if me is null then raise exception 'no matching profile'; end if;
  if me = p_other_profile_id then raise exception 'cannot message yourself'; end if;
  if not is_active_subscriber() then raise exception 'subscription_inactive'; end if;
  if me < p_other_profile_id then a := me; b := p_other_profile_id;
  else a := p_other_profile_id; b := me;
  end if;
  -- Atomic insert-or-return: if two requests for the same pair land at
  -- nearly the same time (e.g. a double-tap), this can't collide the way
  -- a separate "check, then insert" would — the database resolves the
  -- conflict itself and always hands back the one true row for this pair.
  insert into conversations (user_a, user_b) values (a, b)
  on conflict (user_a, user_b) do update set user_a = excluded.user_a
  returning * into convo;
  return convo;
end;
$$;
grant execute on function get_or_create_conversation(uuid) to anon, authenticated;

drop function if exists send_message(uuid, text, text, text);
create or replace function send_message(p_conversation_id uuid, p_kind text, p_body text, p_image_path text, p_reply_to_id uuid default null)
returns messages
language plpgsql security definer
as $$
declare
  me uuid;
  new_msg messages;
begin
  select id into me from profiles where auth_uid = auth.uid();
  if me is null then raise exception 'no matching profile'; end if;
  if not exists (
    select 1 from conversations c where c.id = p_conversation_id and (c.user_a = me or c.user_b = me)
  ) then
    raise exception 'not a participant of this conversation';
  end if;
  if not (select p.is_active from profiles p where p.id = me) then
    raise exception 'account_deactivated';
  end if;
  -- Reject anything that isn't a known kind, and for file-backed kinds,
  -- require the path to look exactly like what the app itself generates
  -- ({uuid}/{timestamp}.{ext}). This blocks a malicious caller from putting
  -- quotes/angle-brackets into image_path via a direct RPC call and using
  -- it to break out of the HTML attributes the client renders it into.
  if p_kind not in ('text', 'image', 'voice') then
    raise exception 'invalid_message_kind';
  end if;
  if p_kind = 'text' and (p_body is null or length(trim(p_body)) = 0 or length(p_body) > 4000) then
    raise exception 'invalid_message_body';
  end if;
  if p_kind = 'image' and (p_image_path is null or p_image_path !~ '^[0-9a-fA-F-]{36}/[0-9]+\.(jpg|jpeg|png|webp)$') then
    raise exception 'invalid_image_path';
  end if;
  if p_kind = 'voice' and (p_image_path is null or p_image_path !~ '^[0-9a-fA-F-]{36}/[0-9]+\.(mp3|m4a|webm)$') then
    raise exception 'invalid_voice_path';
  end if;
  -- Same real, always-enforced check the directory uses — not a separate
  -- switch that can drift out of sync with it.
  if not is_active_subscriber() then
    raise exception 'subscription_inactive';
  end if;
  if p_reply_to_id is not null and not exists (
    select 1 from messages m where m.id = p_reply_to_id and m.conversation_id = p_conversation_id
  ) then
    raise exception 'reply target not found in this conversation';
  end if;
  insert into messages (conversation_id, sender_id, kind, body, image_path, reply_to_id)
  values (p_conversation_id, me, p_kind, p_body, p_image_path, p_reply_to_id)
  returning * into new_msg;
  update conversations set
    last_message_at = now(),
    last_read_a = case when user_a = me then now() else last_read_a end,
    last_read_b = case when user_b = me then now() else last_read_b end
  where id = p_conversation_id;
  return new_msg;
end;
$$;
grant execute on function send_message(uuid, text, text, text, uuid) to anon, authenticated;

create or replace function edit_message(p_message_id uuid, p_body text)
returns messages
language plpgsql security definer
as $$
declare
  me uuid;
  updated_msg messages;
begin
  select id into me from profiles where auth_uid = auth.uid();
  if me is null then raise exception 'no matching profile'; end if;
  if not (select p.is_active from profiles p where p.id = me) then
    raise exception 'account_deactivated';
  end if;
  if p_body is null or length(trim(p_body)) = 0 or length(p_body) > 4000 then
    raise exception 'invalid_message_body';
  end if;
  if not exists (
    select 1 from messages m where m.id = p_message_id and m.sender_id = me and m.kind = 'text'
  ) then
    raise exception 'message not found or not editable';
  end if;
  update messages set body = p_body, edited_at = now()
  where id = p_message_id
  returning * into updated_msg;
  return updated_msg;
end;
$$;
grant execute on function edit_message(uuid, text) to anon, authenticated;

create or replace function mark_conversation_read(p_conversation_id uuid)
returns void
language plpgsql security definer
as $$
declare
  me uuid;
begin
  select id into me from profiles where auth_uid = auth.uid();
  if me is null then raise exception 'no matching profile'; end if;
  update conversations set
    last_read_a = case when user_a = me then now() else last_read_a end,
    last_read_b = case when user_b = me then now() else last_read_b end
  where id = p_conversation_id and (user_a = me or user_b = me);
end;
$$;
grant execute on function mark_conversation_read(uuid) to anon, authenticated;

-- Lets a user mute (or unmute) ALL push notifications for themselves —
-- messages and other notification types alike. Toggled by long-pressing
-- the bell icon on the directory page.
create or replace function set_push_muted(p_muted boolean)
returns void
language plpgsql security definer
as $$
begin
  update profiles set push_muted = p_muted where auth_uid = auth.uid();
end;
$$;
grant execute on function set_push_muted(boolean) to anon, authenticated;

-- superseded by set_push_muted() above (global mute replaced per-conversation mute)
drop function if exists set_conversation_muted(uuid, boolean);

create or replace function get_unread_counts()
returns table(conversation_id uuid, unread_count bigint)
language sql security definer set search_path = public
as $$
  select m.conversation_id, count(*)::bigint
  from messages m
  join conversations c on c.id = m.conversation_id
  where (c.user_a = my_profile_id() or c.user_b = my_profile_id())
    and m.sender_id <> my_profile_id()
    and m.created_at > (case when c.user_a = my_profile_id() then c.last_read_a else c.last_read_b end)
    and not exists (
      select 1 from message_hides h where h.message_id = m.id and h.profile_id = my_profile_id()
    )
  group by m.conversation_id;
$$;
grant execute on function get_unread_counts() to anon, authenticated;

-- Same as get_unread_counts() above, but takes an explicit profile id
-- instead of relying on auth.uid() / my_profile_id() — needed because the
-- send-push edge function runs with the service-role key and has no user
-- session. Only ever called server-side (service role), so it does not
-- need to be granted to anon/authenticated.
create or replace function get_unread_count_for(p_profile_id uuid)
returns bigint
language sql security definer set search_path = public
as $$
  select coalesce(sum(cnt), 0)::bigint from (
    select count(*) as cnt
    from messages m
    join conversations c on c.id = m.conversation_id
    where (c.user_a = p_profile_id or c.user_b = p_profile_id)
      and m.sender_id <> p_profile_id
      and m.created_at > (case when c.user_a = p_profile_id then c.last_read_a else c.last_read_b end)
      and not exists (
        select 1 from message_hides h where h.message_id = m.id and h.profile_id = p_profile_id
      )
    group by m.conversation_id
  ) sub;
$$;

-- ============================================================
-- Row Level Security
-- ============================================================
alter table profiles enable row level security;
alter table subscription_requests enable row level security;
alter table pin_reset_requests enable row level security;
alter table conversations enable row level security;
alter table messages enable row level security;
alter table admin_allowlist enable row level security;

-- profiles: a user can only ever see their own row directly; admin sees
-- all. Other users' profiles are NEVER exposed through direct table
-- access (that would hand out `phone` and `pin_hash` to anyone with the
-- public anon key, not just the safe fields the app displays) — browsing
-- other people goes exclusively through get_directory() and
-- get_public_profiles(), which return only name/dob/district/avatar/
-- last_seen_at and enforce the same subscriber-gating server-side.
drop policy if exists "profiles_select_own_or_gated" on profiles;
drop policy if exists "profiles_select_own_or_admin" on profiles;
create policy "profiles_select_own_or_admin" on profiles for select
  using (
    auth_uid = auth.uid()
    or is_admin()
  );
drop policy if exists "profiles_insert_own" on profiles;
create policy "profiles_insert_own" on profiles for insert with check (auth_uid = auth.uid());
drop policy if exists "profiles_update_own_or_admin" on profiles;
create policy "profiles_update_own_or_admin" on profiles for update
  using (auth_uid = auth.uid() or is_admin())
  with check (auth_uid = auth.uid() or is_admin());
drop policy if exists "profiles_delete_admin" on profiles;
create policy "profiles_delete_admin" on profiles for delete using (is_admin());

-- only an admin (or a trusted server-side process, like the pesapal-ipn
-- Edge Function, using the service role key — never exposed to users) may
-- move subscription_status to 'active'/'expired', change the expiry date,
-- or toggle is_active. A user MAY set their own status to 'pending' (the
-- self-service "I've paid" step) but nothing further.
--
-- One narrow exception: flipping 'active' straight to 'expired' is always
-- allowed, but ONLY when the row's own subscription_expires_at has
-- already passed. This lets the expire_lapsed_subscriptions() cleanup job
-- (below) keep the label honest on a schedule without needing elevated
-- database privileges. It grants nothing extra to a regular user either —
-- is_active_subscriber() already treats a passed expiry as inactive
-- regardless of this label, so setting it themselves a moment earlier
-- changes nothing they don't already lack.
create or replace function protect_admin_fields()
returns trigger language plpgsql as $$
begin
  if not is_admin() and auth.role() <> 'service_role' then
    if new.subscription_status is distinct from 'pending' then
      if new.subscription_status = 'expired'
         and old.subscription_status = 'active'
         and old.subscription_expires_at is not null
         and old.subscription_expires_at <= now()
      then
        -- allowed: new.subscription_status keeps the caller's 'expired' value
      else
        new.subscription_status := old.subscription_status;
      end if;
    end if;
    new.subscription_expires_at := old.subscription_expires_at;
    new.is_active := old.is_active;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_protect_admin_fields on profiles;
create trigger trg_protect_admin_fields before update on profiles
  for each row execute function protect_admin_fields();

-- subscription_requests
-- A direct client insert must always start out 'pending' — approving or
-- rejecting a request is only ever done by an admin (requests_update_admin
-- below) or by the service-role pesapal-ipn function, never by the
-- inserting user themselves. Without this, nothing stopped a direct
-- INSERT from setting status straight to 'approved'; that alone didn't
-- grant anything (activating a subscription is a separate, admin/
-- service-role-only update to profiles), but it's tightened here anyway
-- so a stray row can't even look approved.
drop policy if exists "requests_insert_own" on subscription_requests;
create policy "requests_insert_own" on subscription_requests for insert
  with check (
    exists (select 1 from profiles p where p.id = profile_id and p.auth_uid = auth.uid())
    and status = 'pending'
  );
drop policy if exists "requests_select_own_or_admin" on subscription_requests;
create policy "requests_select_own_or_admin" on subscription_requests for select
  using (exists (select 1 from profiles p where p.id = profile_id and p.auth_uid = auth.uid()) or is_admin());
drop policy if exists "requests_update_admin" on subscription_requests;
create policy "requests_update_admin" on subscription_requests for update using (is_admin());

-- pin_reset_requests: no insert policy — rows are only ever created by the
-- security-definer request_pin_reset() function, since the whole point is
-- the requester isn't (and can't be) logged in as the profile they're
-- resetting. Admin can read pending requests and reject (approve happens
-- through admin_set_temp_pin(), also security-definer).
drop policy if exists "pin_resets_select_admin" on pin_reset_requests;
create policy "pin_resets_select_admin" on pin_reset_requests for select using (is_admin());
drop policy if exists "pin_resets_update_admin" on pin_reset_requests;
create policy "pin_resets_update_admin" on pin_reset_requests for update using (is_admin());

-- conversations: only the two participants (or admin) can see a conversation row
drop policy if exists "conversations_select_participant" on conversations;
create policy "conversations_select_participant" on conversations for select
  using (user_a = my_profile_id() or user_b = my_profile_id() or is_admin());

-- messages: only participants of the parent conversation (or admin) can read.
-- All writes go through send_message() (security definer), so no insert policy is needed.
drop policy if exists "messages_select_participant" on messages;
create policy "messages_select_participant" on messages for select
  using (
    exists (
      select 1 from conversations c
      where c.id = conversation_id and (c.user_a = my_profile_id() or c.user_b = my_profile_id())
    ) or is_admin()
  );

-- messages: a user can delete only messages they themselves sent
drop policy if exists "messages_delete_own" on messages;
create policy "messages_delete_own" on messages for delete
  using (sender_id = my_profile_id());

-- conversations: either participant can delete the whole chat — their
-- messages cascade-delete automatically via the existing foreign key
drop policy if exists "conversations_delete_participant" on conversations;
create policy "conversations_delete_participant" on conversations for delete
  using (user_a = my_profile_id() or user_b = my_profile_id());

-- message_hides: a user can only manage their own "delete for me" markers
alter table message_hides enable row level security;
drop policy if exists "message_hides_own" on message_hides;
create policy "message_hides_own" on message_hides for all
  using (profile_id = my_profile_id())
  with check (profile_id = my_profile_id());

-- push_subscriptions: a user can only manage their own device subscriptions.
-- No policy is needed for the sending side — the edge function that
-- actually delivers pushes uses the service_role key, which bypasses RLS
-- entirely, same as every other security-definer function in this file.
alter table push_subscriptions enable row level security;
drop policy if exists "push_subscriptions_own" on push_subscriptions;
create policy "push_subscriptions_own" on push_subscriptions for all
  using (profile_id = my_profile_id())
  with check (profile_id = my_profile_id());

-- storage: avatars are public-read (shown in the directory), owner-write only
drop policy if exists "avatars_read_all" on storage.objects;
create policy "avatars_read_all" on storage.objects for select using (bucket_id = 'avatars');
drop policy if exists "avatars_write_own" on storage.objects;
create policy "avatars_write_own" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = my_profile_id()::text);
drop policy if exists "avatars_delete_own" on storage.objects;
create policy "avatars_delete_own" on storage.objects for delete
  using (bucket_id = 'avatars' and ((storage.foldername(name))[1] = my_profile_id()::text or is_admin()));

-- storage: chat images are only readable/writable by the two people in
-- that conversation (path is {conversation_id}/{filename})
drop policy if exists "chat_images_rw_participants" on storage.objects;
create policy "chat_images_rw_participants" on storage.objects for select
  using (
    bucket_id = 'chat-images'
    and exists (
      select 1 from conversations c
      where c.id::text = (storage.foldername(name))[1]
        and (c.user_a = my_profile_id() or c.user_b = my_profile_id())
    )
  );
drop policy if exists "chat_images_insert_participants" on storage.objects;
create policy "chat_images_insert_participants" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'chat-images'
    and exists (
      select 1 from conversations c
      where c.id::text = (storage.foldername(name))[1]
        and (c.user_a = my_profile_id() or c.user_b = my_profile_id())
    )
  );
drop policy if exists "chat_images_delete_participants" on storage.objects;
create policy "chat_images_delete_participants" on storage.objects for delete
  using (
    bucket_id = 'chat-images'
    and (
      is_admin()
      or exists (
        select 1 from conversations c
        where c.id::text = (storage.foldername(name))[1]
          and (c.user_a = my_profile_id() or c.user_b = my_profile_id())
      )
    )
  );

-- voice-notes: same participant-only access pattern as chat-images
-- (path is {conversation_id}/{filename})
drop policy if exists "voice_notes_rw_participants" on storage.objects;
create policy "voice_notes_rw_participants" on storage.objects for select
  using (
    bucket_id = 'voice-notes'
    and exists (
      select 1 from conversations c
      where c.id::text = (storage.foldername(name))[1]
        and (c.user_a = my_profile_id() or c.user_b = my_profile_id())
    )
  );
drop policy if exists "voice_notes_insert_participants" on storage.objects;
create policy "voice_notes_insert_participants" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'voice-notes'
    and exists (
      select 1 from conversations c
      where c.id::text = (storage.foldername(name))[1]
        and (c.user_a = my_profile_id() or c.user_b = my_profile_id())
    )
  );
drop policy if exists "voice_notes_delete_participants" on storage.objects;
create policy "voice_notes_delete_participants" on storage.objects for delete
  using (
    bucket_id = 'voice-notes'
    and (
      is_admin()
      or exists (
        select 1 from conversations c
        where c.id::text = (storage.foldername(name))[1]
          and (c.user_a = my_profile_id() or c.user_b = my_profile_id())
      )
    )
  );

-- admin_allowlist: no direct client access; only is_admin() reads it (bypasses RLS via security definer)

-- ads: everyone can see active ads (that's the point); only admin manages them
alter table ads enable row level security;
drop policy if exists "ads_read_active_or_admin" on ads;
create policy "ads_read_active_or_admin" on ads for select using (is_active or is_admin());
drop policy if exists "ads_write_admin" on ads;
create policy "ads_write_admin" on ads for all using (is_admin()) with check (is_admin());

drop policy if exists "ads_bucket_read_all" on storage.objects;
create policy "ads_bucket_read_all" on storage.objects for select using (bucket_id = 'ads');
drop policy if exists "ads_bucket_write_admin" on storage.objects;
create policy "ads_bucket_write_admin" on storage.objects for insert to authenticated
  with check (bucket_id = 'ads' and is_admin());
drop policy if exists "ads_bucket_delete_admin" on storage.objects;
create policy "ads_bucket_delete_admin" on storage.objects for delete
  using (bucket_id = 'ads' and is_admin());

-- statuses: an active subscriber (or admin) can see any unexpired status
-- from a currently-active account; a user can always see their own even if
-- it's expired or they've lapsed. Deactivating someone hides their statuses
-- from everyone else immediately (RLS is checked on every query) — no
-- separate cleanup needed, and it reverses itself the instant they're
-- reactivated. Only the owner can post or delete their own statuses.
alter table statuses enable row level security;
drop policy if exists "statuses_select_subscriber_or_own" on statuses;
create policy "statuses_select_subscriber_or_own" on statuses for select
  using (
    profile_id = my_profile_id()
    or is_admin()
    or (
      expires_at > now()
      and is_active_subscriber()
      and profile_is_active(statuses.profile_id)
    )
  );
drop policy if exists "statuses_insert_own" on statuses;
create policy "statuses_insert_own" on statuses for insert to authenticated
  with check (profile_id = my_profile_id());
drop policy if exists "statuses_delete_own" on statuses;
create policy "statuses_delete_own" on statuses for delete
  using (profile_id = my_profile_id());

-- status_comments: anyone who can see the status (owner, admin, or an
-- active subscriber while it hasn't expired) can read and post comments on
-- it — a public thread on the post, same visibility as the status itself.
-- A comment can be removed by whoever wrote it, the post's owner
-- (moderation on your own post), or admin.
alter table status_comments enable row level security;
drop policy if exists "status_comments_select_if_status_visible" on status_comments;
drop policy if exists "status_comments_select_owner_author_or_reply_target" on status_comments;
drop policy if exists "status_comments_select_owner_or_admin" on status_comments;
-- migrate existing deployments: the parent-profile lookup from an earlier
-- version of this feature is no longer needed (comments are a public
-- thread now, not restricted to the post owner) — safe to drop only after
-- the policy above (which depended on it) has just been dropped
drop function if exists status_comment_parent_profile(uuid);
create policy "status_comments_select_if_status_visible" on status_comments for select
  using (
    is_admin()
    or exists (
      select 1 from statuses s
      where s.id = status_comments.status_id
        and (
          s.profile_id = my_profile_id()
          or is_admin()
          or (s.expires_at > now() and is_active_subscriber())
        )
    )
  );
drop policy if exists "status_comments_insert_own" on status_comments;
create policy "status_comments_insert_own" on status_comments for insert to authenticated
  with check (
    profile_id = my_profile_id()
    and exists (
      select 1 from statuses s
      where s.id = status_comments.status_id
        and (
          s.profile_id = my_profile_id()
          or is_admin()
          or (s.expires_at > now() and is_active_subscriber())
        )
    )
    and (
      reply_to_id is null
      or status_comment_parent_status(reply_to_id) = status_comments.status_id
    )
  );
drop policy if exists "status_comments_delete_own_or_post_owner" on status_comments;
create policy "status_comments_delete_own_or_post_owner" on status_comments for delete
  using (
    profile_id = my_profile_id()
    or is_admin()
    or exists (select 1 from statuses s where s.id = status_comments.status_id and s.profile_id = my_profile_id())
  );

-- status_likes: same visibility as status_comments — anyone who can see the
-- status can see who's liked it, and can like/unlike it themselves. Only
-- your own like row can be inserted or removed by you (or admin, e.g. for
-- moderation cleanup).
alter table status_likes enable row level security;
drop policy if exists "status_likes_select_if_status_visible" on status_likes;
create policy "status_likes_select_if_status_visible" on status_likes for select
  using (
    is_admin()
    or exists (
      select 1 from statuses s
      where s.id = status_likes.status_id
        and (
          s.profile_id = my_profile_id()
          or is_admin()
          or (s.expires_at > now() and is_active_subscriber())
        )
    )
  );
drop policy if exists "status_likes_insert_own" on status_likes;
create policy "status_likes_insert_own" on status_likes for insert to authenticated
  with check (
    profile_id = my_profile_id()
    and exists (
      select 1 from statuses s
      where s.id = status_likes.status_id
        and (
          s.profile_id = my_profile_id()
          or is_admin()
          or (s.expires_at > now() and is_active_subscriber())
        )
    )
  );
drop policy if exists "status_likes_delete_own" on status_likes;
create policy "status_likes_delete_own" on status_likes for delete
  using (profile_id = my_profile_id() or is_admin());

-- status_views: strictly private per-viewer bookkeeping. A user can only
-- ever insert or select their OWN view rows — there is no policy that lets
-- anyone read another viewer's rows, so it's impossible to query who else
-- has seen a status (deliberately different from the removed "viewed by"
-- feature, which this does not bring back).
alter table status_views enable row level security;
drop policy if exists "status_views_select_own" on status_views;
create policy "status_views_select_own" on status_views for select
  using (viewer_id = my_profile_id());
drop policy if exists "status_views_insert_own" on status_views;
create policy "status_views_insert_own" on status_views for insert to authenticated
  with check (
    viewer_id = my_profile_id()
    and exists (
      select 1 from statuses s
      where s.id = status_views.status_id
        and (
          s.profile_id = my_profile_id()
          or is_admin()
          or (s.expires_at > now() and is_active_subscriber())
        )
    )
  );

-- notifications: a user can only ever see and manage their own — there is
-- deliberately no insert policy for regular users, since rows are only ever
-- created by the notify_comment_reply trigger (which runs as the function
-- owner and so bypasses RLS, same as the other security-definer helpers).
alter table notifications enable row level security;
drop policy if exists "notifications_select_own" on notifications;
create policy "notifications_select_own" on notifications for select
  using (profile_id = my_profile_id() or is_admin());
drop policy if exists "notifications_update_own" on notifications;
create policy "notifications_update_own" on notifications for update to authenticated
  using (profile_id = my_profile_id())
  with check (profile_id = my_profile_id());
drop policy if exists "notifications_delete_own" on notifications;
create policy "notifications_delete_own" on notifications for delete
  using (profile_id = my_profile_id() or is_admin());

-- storage: status photos are readable by the owner or any active subscriber
-- (path is {profile_id}/{filename}); only the owner can upload/delete
drop policy if exists "statuses_bucket_read_subscriber_or_own" on storage.objects;
create policy "statuses_bucket_read_subscriber_or_own" on storage.objects for select
  using (
    bucket_id = 'statuses'
    and (
      (storage.foldername(name))[1] = my_profile_id()::text
      or is_admin()
      or is_active_subscriber()
    )
  );
drop policy if exists "statuses_bucket_write_own" on storage.objects;
create policy "statuses_bucket_write_own" on storage.objects for insert to authenticated
  with check (bucket_id = 'statuses' and (storage.foldername(name))[1] = my_profile_id()::text);
drop policy if exists "statuses_bucket_delete_own" on storage.objects;
create policy "statuses_bucket_delete_own" on storage.objects for delete
  using (bucket_id = 'statuses' and ((storage.foldername(name))[1] = my_profile_id()::text or is_admin()));

-- ============================================================
-- Realtime: instant chat + live admin dashboard updates
-- ============================================================
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'messages') then
    alter publication supabase_realtime add table messages;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'subscription_requests') then
    alter publication supabase_realtime add table subscription_requests;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'conversations') then
    alter publication supabase_realtime add table conversations;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'pin_reset_requests') then
    alter publication supabase_realtime add table pin_reset_requests;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'profiles') then
    alter publication supabase_realtime add table profiles;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'ads') then
    alter publication supabase_realtime add table ads;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'statuses') then
    alter publication supabase_realtime add table statuses;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'status_comments') then
    alter publication supabase_realtime add table status_comments;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'status_likes') then
    alter publication supabase_realtime add table status_likes;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'notifications') then
    alter publication supabase_realtime add table notifications;
  end if;
end $$;

-- ============================================================
-- Auto-delete old messages (keeps database + storage usage bounded
-- on the free tier)
-- ------------------------------------------------------------
-- Chat messages older than 60 days are deleted automatically, along with
-- their photo/voice-note files in storage (text-only messages just get
-- deleted, there's no file to clean up). This does NOT touch statuses
-- (those already auto-expire after 24h on their own), profiles, or
-- anything else — only the messages table and the two chat-media buckets.
-- ============================================================
create or replace function cleanup_old_messages()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- remove the actual files first, so nothing gets orphaned in storage
  delete from storage.objects
  where bucket_id = 'chat-images'
    and name in (
      select image_path from messages
      where kind = 'image' and image_path is not null and created_at < now() - interval '60 days'
    );

  delete from storage.objects
  where bucket_id = 'voice-notes'
    and name in (
      select image_path from messages
      where kind = 'voice' and image_path is not null and created_at < now() - interval '60 days'
    );

  -- then the message rows themselves (message_hides cascade-deletes with them)
  delete from messages where created_at < now() - interval '60 days';
end;
$$;

-- run it once a day at 03:00 UTC. Re-running this schema.sql is safe —
-- any previous job with this name is unscheduled first so you never end
-- up with duplicate jobs.
create extension if not exists pg_cron;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'cleanup-old-messages') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'cleanup-old-messages';
  end if;
end $$;

select cron.schedule('cleanup-old-messages', '0 3 * * *', $$select cleanup_old_messages();$$);
-- ============================================================
-- Patch: add a shared secret to the push-notification trigger
-- ------------------------------------------------------------
-- Paste this into Supabase's SQL Editor and run it AFTER you've:
--   1. Redeployed send-push with the new code (checks X-Internal-Secret)
--   2. Picked a random secret and set it in TWO places:
--
--      a) As an edge function secret:
--         supabase secrets set PUSH_TRIGGER_SECRET=<your random secret>
--
--      b) As a Postgres database setting, so the trigger can read it
--         (run this in the SQL Editor, with YOUR real secret):
--         alter database postgres set app.settings.push_trigger_secret = '<your random secret>';
--
--         Use the SAME value in both places. A long random string works
--         well, e.g. generate one with: openssl rand -hex 32
--
-- This replaces notify_send_push() so the call to send-push includes an
-- X-Internal-Secret header. send-push now rejects any request that's
-- missing this header or has the wrong value — closing the hole where
-- anyone with the public anon key could POST a crafted body directly to
-- send-push and trigger a fake notification to any user.
-- ============================================================

create or replace function notify_send_push()
returns trigger
language plpgsql
security definer
as $$
declare
  recipient_id uuid;
  recipient_muted boolean := false;
begin
  if TG_TABLE_NAME = 'messages' then
    select case
      when user_a = NEW.sender_id then user_b
      when user_b = NEW.sender_id then user_a
    end into recipient_id
    from conversations where id = NEW.conversation_id;
  elsif TG_TABLE_NAME = 'notifications' then
    recipient_id := NEW.profile_id;
  end if;

  if recipient_id is not null then
    select push_muted into recipient_muted from profiles where id = recipient_id;
    if recipient_muted then
      return NEW;
    end if;
  end if;

  perform net.http_post(
    url := 'https://tgpqzphfmhactykxahqn.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer sb_publishable_QTUByYlNoDQ8RoJ_usnAJw_p3VAVwLt',
      'X-Internal-Secret', current_setting('app.settings.push_trigger_secret', true)
    ),
    body := jsonb_build_object(
      'type', 'INSERT',
      'table', TG_TABLE_NAME,
      'record', to_jsonb(NEW)
    )
  );
  return NEW;
end;
$$;

-- (the two triggers that call this function already exist and don't need
-- to be re-created — replacing the function's body is enough)
-- ============================================================
-- Patch: close the statuses-bucket read gap
-- ------------------------------------------------------------
-- The `statuses` table's own select policy only shows a status if it's
-- still unexpired AND the poster's account is still active. The storage
-- policy that gates the underlying photo FILE didn't check either of
-- those — so once a status expired (24h) or its poster was deactivated,
-- the app stopped showing the post, but the image file itself stayed
-- downloadable by any active subscriber who still had its path. This
-- brings the storage policy in line with the table policy.
-- ============================================================

drop policy if exists "statuses_bucket_read_subscriber_or_own" on storage.objects;
create policy "statuses_bucket_read_subscriber_or_own" on storage.objects for select
  using (
    bucket_id = 'statuses'
    and (
      (storage.foldername(name))[1] = my_profile_id()::text
      or is_admin()
      or (
        is_active_subscriber()
        and profile_is_active((storage.foldername(name))[1]::uuid)
        and exists (
          select 1 from statuses s
          where s.image_path = name
            and s.expires_at > now()
        )
      )
    )
  );

-- ============================================================
-- Patch: keep subscription_status accurate after it lapses
-- ------------------------------------------------------------
-- Real access control never depended on this label — is_active_subscriber(),
-- get_directory(), and send_message() all check subscription_expires_at
-- directly, so a lapsed user was already correctly blocked from browsing
-- and chatting the instant their time ran out. But nothing ever flipped
-- the profiles.subscription_status column itself from 'active' to
-- 'expired', which meant:
--   - the user's own "My profile" screen kept showing "active" (fixed
--     separately in index.html to check the real expiry too, but this
--     keeps the underlying data itself honest)
--   - admin.html's user list and "active users" count kept counting
--     lapsed accounts as active, with no visual way to tell who'd
--     actually lapsed
--
-- This adds a daily job, same pattern as cleanup-old-messages above, that
-- flips the label once the expiry date has passed. It changes nothing
-- about who can access what — that was already correct — it only keeps
-- the status people and the admin SEE in sync with reality.
-- ============================================================
create or replace function expire_lapsed_subscriptions()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- security definer bypasses the profiles RLS SELECT/UPDATE policies (own
  -- row or admin only) so this can see and update every lapsed row, not
  -- just one. The trg_protect_admin_fields trigger still fires on this
  -- update as normal — it explicitly allows exactly this one transition
  -- (see protect_admin_fields() above), so no privilege escalation of any
  -- kind is needed here.
  update profiles
  set subscription_status = 'expired'
  where subscription_status = 'active'
    and subscription_expires_at is not null
    and subscription_expires_at <= now();
end;
$$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'expire-lapsed-subscriptions') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'expire-lapsed-subscriptions';
  end if;
end $$;

-- runs once an hour; access control itself doesn't depend on this timing,
-- it only keeps the displayed status reasonably fresh
select cron.schedule('expire-lapsed-subscriptions', '5 * * * *', $$select expire_lapsed_subscriptions();$$);

-- ============================================================
-- Patch: clean up expired status photos (storage was filling up
-- forever with no cleanup)
-- ------------------------------------------------------------
-- Statuses already "expire" after 24h in the sense that nobody can see
-- them anymore — every read policy for the `statuses` table and the
-- `statuses` storage bucket already requires expires_at > now(). But
-- nothing ever actually DELETED the row or its photo file once that
-- happened, so both just sat there taking up database and storage space
-- forever. On the free tier's 1GB storage cap, that adds up fast.
--
-- Mirrors the exact same two-step pattern as cleanup_old_messages()
-- above (delete the storage file first, then the row), and is just as
-- safe to re-run — this whole block uses create-or-replace / drop-if-
-- exists throughout, same as everywhere else in this file.
--
-- The 1-hour buffer past expires_at is just a small safety margin, not a
-- functional requirement — read access is already blocked the instant
-- expires_at passes, this only delays the actual delete slightly so
-- there's no chance of racing a request that's mid-flight right at the
-- expiry boundary.
--
-- This does NOT touch statuses that haven't expired yet, comments/likes
-- on other people's statuses, or anything outside the `statuses` table
-- and the `statuses` storage bucket.
-- ============================================================
create or replace function cleanup_expired_statuses()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- remove the photo files first, so nothing gets orphaned in storage
  delete from storage.objects
  where bucket_id = 'statuses'
    and name in (
      select image_path from statuses
      where image_path is not null and expires_at < now() - interval '1 hour'
    );

  -- then the status rows themselves — status_comments, status_likes,
  -- status_views, and notifications referencing them all cascade-delete
  -- automatically via their existing foreign keys
  delete from statuses where expires_at < now() - interval '1 hour';
end;
$$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'cleanup-expired-statuses') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'cleanup-expired-statuses';
  end if;
end $$;

-- runs once a day, 15 minutes after the existing message cleanup job so
-- they never overlap
select cron.schedule('cleanup-expired-statuses', '15 3 * * *', $$select cleanup_expired_statuses();$$);

-- ============================================================
-- Patch: directory live-updates never actually reached other users
-- ------------------------------------------------------------
-- profiles' own security rule correctly says a user can only read
-- their OWN row directly (see "profiles_select_own_or_admin" above) —
-- that's intentional, it's what stops phone numbers and PIN hashes
-- leaking to anyone with the app's public key. But the "live directory"
-- feature in index.html was built by listening to raw changes on the
-- profiles table itself, and that listener is filtered by that exact
-- same security rule. Net effect: for every regular (non-admin) user,
-- that listener silently never received events for anyone else's
-- profile — new signups, photo/name changes, subscriptions activating,
-- and so on never appeared live. Nothing errored; it just quietly did
-- nothing, and the directory only ever updated on the next page load.
--
-- Fix: broadcast only the same safe, already-public fields
-- get_directory() and get_public_profiles() already hand out to
-- everyone (name/avatar/district/dob/last_seen_at/active flags) over a
-- separate, public Realtime Broadcast channel — not the raw table —
-- so it's never subject to the profiles table's row-level security in
-- the first place. No phone number or PIN data is ever included.
--
-- IMPORTANT: this deliberately does NOT fire on a change to
-- last_seen_at by itself. last_seen_at updates every ~90 seconds for
-- every single online person (the existing "presence heartbeat" in
-- index.html) — broadcasting that to every directory viewer, every 90
-- seconds, for every online user, would multiply into a very large
-- number of realtime messages as more people use the app at once
-- (exactly the kind of scaling problem you asked me to watch out for).
-- Skipping it here means online/offline status still updates normally
-- whenever the directory reloads, just not instantly the second
-- someone opens the app — a deliberate, safe trade-off.
-- ============================================================
create or replace function broadcast_directory_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  rec profiles;
begin
  if TG_OP = 'DELETE' then
    perform realtime.send(
      jsonb_build_object('id', OLD.id, 'deleted', true),
      'profile_changed',
      'directory-updates',
      false
    );
    return OLD;
  end if;

  rec := NEW;

  if TG_OP = 'UPDATE' then
    -- nothing directory-relevant changed (e.g. this was just the
    -- last_seen_at heartbeat, or an internal field like pin_hash) —
    -- skip the broadcast entirely, see note above
    if NEW.name is not distinct from OLD.name
      and NEW.dob is not distinct from OLD.dob
      and NEW.district is not distinct from OLD.district
      and NEW.avatar_path is not distinct from OLD.avatar_path
      and NEW.is_active is not distinct from OLD.is_active
      and NEW.profile_complete is not distinct from OLD.profile_complete
      and NEW.subscription_status is not distinct from OLD.subscription_status
    then
      return NEW;
    end if;
  end if;

  perform realtime.send(
    jsonb_build_object(
      'id', rec.id,
      'name', rec.name,
      'dob', rec.dob,
      'district', rec.district,
      'avatar_path', rec.avatar_path,
      'last_seen_at', rec.last_seen_at,
      'is_active', rec.is_active,
      'profile_complete', rec.profile_complete,
      'subscription_status', rec.subscription_status
    ),
    'profile_changed',
    'directory-updates',
    false
  );

  return rec;
exception when others then
  -- a broadcast hiccup (e.g. a transient Realtime issue) must never be
  -- allowed to block or fail the actual profile write it's attached to
  return coalesce(NEW, OLD);
end;
$$;

drop trigger if exists trg_broadcast_directory_change on profiles;
create trigger trg_broadcast_directory_change
  after insert or update or delete on profiles
  for each row execute function broadcast_directory_change();
