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
  subscription_status text not null default 'inactive'
      check (subscription_status in ('inactive','pending','active','expired')),
  subscription_expires_at timestamptz,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table profiles add column if not exists last_seen_at timestamptz not null default now();

-- ---------- SUBSCRIPTION REQUESTS (manual mobile-money payments) ----------
create table if not exists subscription_requests (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  network text not null check (network in ('MTN','Airtel')),
  transaction_ref text,
  amount integer not null default 3000,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);
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
  constraint status_comments_not_blank check (length(trim(comment_text)) > 0)
);
create index if not exists idx_status_comments_status on status_comments(status_id, created_at);

-- storage buckets
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('chat-images', 'chat-images', false)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('ads', 'ads', true)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('statuses', 'statuses', false)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('voice-notes', 'voice-notes', false)
on conflict (id) do nothing;

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
  -- SUBSCRIPTION_REQUIRED toggle: while false, every active account counts
  -- as a subscriber so people can browse and chat for free. Change the
  -- "true" below to require an active paid subscription again.
  select case when false then (
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

-- ============================================================
-- Registration and login (phone + PIN, no OTP, same pattern as prep+)
-- ============================================================
create or replace function register_with_pin(p_phone text, p_pin text, p_dob date, p_district text)
returns profiles
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
  values (auth.uid(), p_phone, encode(digest(p_pin, 'sha256'), 'hex'), p_dob, p_district)
  returning * into new_row;
  return new_row;
end;
$$;
grant execute on function register_with_pin(text, text, date, text) to anon, authenticated;

create or replace function login_with_pin(p_phone text, p_pin text)
returns profiles
language plpgsql security definer
as $$
declare
  match_row profiles;
  attempt login_attempts;
  new_fail_count int;
  lock_minutes numeric;
begin
  if auth.uid() is null then raise exception 'no active session'; end if;

  select * into attempt from login_attempts where phone = p_phone;
  if attempt.locked_until is not null and attempt.locked_until > now() then
    raise exception 'too_many_attempts';
  end if;

  select * into match_row from profiles where phone = p_phone;
  if match_row is null or match_row.pin_hash <> encode(digest(p_pin, 'sha256'), 'hex') then
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
    raise exception 'invalid_credentials';
  end if;

  if not match_row.is_active then raise exception 'account_deactivated'; end if;

  delete from login_attempts where phone = p_phone;
  update profiles set auth_uid = auth.uid() where id = match_row.id returning * into match_row;
  return match_row;
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
begin
  update profiles set
    name = p_name,
    avatar_path = coalesce(p_avatar_path, avatar_path),
    lat = case when p_share_location then p_lat else null end,
    lng = case when p_share_location then p_lng else null end,
    share_location = p_share_location,
    profile_complete = true
  where auth_uid = auth.uid()
  returning * into updated;
  if updated is null then raise exception 'no matching profile'; end if;
  return updated;
end;
$$;
grant execute on function complete_profile(text, text, double precision, double precision, boolean) to anon, authenticated;

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
begin
  if p_dob is null or p_dob > (current_date - interval '18 years') then
    raise exception 'must_be_18';
  end if;
  update profiles set
    name = p_name,
    dob = p_dob,
    district = p_district,
    lat = case when p_share_location then p_lat else null end,
    lng = case when p_share_location then p_lng else null end,
    share_location = p_share_location
  where auth_uid = auth.uid()
  returning * into updated;
  if updated is null then raise exception 'no matching profile'; end if;
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
  if me.pin_hash <> encode(digest(p_current_pin, 'sha256'), 'hex') then
    raise exception 'invalid_credentials';
  end if;
  update profiles set pin_hash = encode(digest(p_new_pin, 'sha256'), 'hex') where id = me.id;
end;
$$;
grant execute on function change_pin(text, text) to anon, authenticated;

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
  if me < p_other_profile_id then a := me; b := p_other_profile_id;
  else a := p_other_profile_id; b := me;
  end if;
  select * into convo from conversations where user_a = a and user_b = b;
  if convo is null then
    insert into conversations (user_a, user_b) values (a, b) returning * into convo;
  end if;
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
  require_subscription boolean := false; -- flip to true later to require an active subscription before people can chat
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
  if require_subscription and not (
    select p.subscription_status = 'active'
      and (p.subscription_expires_at is null or p.subscription_expires_at > now())
    from profiles p where p.id = me
  ) then
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

-- ============================================================
-- Row Level Security
-- ============================================================
alter table profiles enable row level security;
alter table subscription_requests enable row level security;
alter table conversations enable row level security;
alter table messages enable row level security;
alter table admin_allowlist enable row level security;

-- profiles: a user can always see their own row; can browse OTHER
-- completed profiles only while an active subscriber; admin sees all.
-- This is the actual paywall for the directory.
drop policy if exists "profiles_select_own_or_gated" on profiles;
create policy "profiles_select_own_or_gated" on profiles for select
  using (
    auth_uid = auth.uid()
    or is_admin()
    or (profile_complete and is_active and is_active_subscriber())
  );
drop policy if exists "profiles_insert_own" on profiles;
create policy "profiles_insert_own" on profiles for insert with check (auth_uid = auth.uid());
drop policy if exists "profiles_update_own_or_admin" on profiles;
create policy "profiles_update_own_or_admin" on profiles for update
  using (auth_uid = auth.uid() or is_admin())
  with check (auth_uid = auth.uid() or is_admin());
drop policy if exists "profiles_delete_admin" on profiles;
create policy "profiles_delete_admin" on profiles for delete using (is_admin());

-- only an admin may move subscription_status to 'active'/'expired', change
-- the expiry date, or toggle is_active. A user MAY set their own status to
-- 'pending' (that's the self-service "I've paid" step) but nothing further.
create or replace function protect_admin_fields()
returns trigger language plpgsql as $$
begin
  if not is_admin() then
    if new.subscription_status is distinct from 'pending' then
      new.subscription_status := old.subscription_status;
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
drop policy if exists "requests_insert_own" on subscription_requests;
create policy "requests_insert_own" on subscription_requests for insert
  with check (exists (select 1 from profiles p where p.id = profile_id and p.auth_uid = auth.uid()));
drop policy if exists "requests_select_own_or_admin" on subscription_requests;
create policy "requests_select_own_or_admin" on subscription_requests for select
  using (exists (select 1 from profiles p where p.id = profile_id and p.auth_uid = auth.uid()) or is_admin());
drop policy if exists "requests_update_admin" on subscription_requests;
create policy "requests_update_admin" on subscription_requests for update using (is_admin());

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

-- statuses: an active subscriber (or admin) can see any unexpired status;
-- a user can always see their own even if it's expired or they've lapsed.
-- Only the owner can post or delete their own statuses.
alter table statuses enable row level security;
drop policy if exists "statuses_select_subscriber_or_own" on statuses;
create policy "statuses_select_subscriber_or_own" on statuses for select
  using (
    profile_id = my_profile_id()
    or is_admin()
    or (expires_at > now() and is_active_subscriber())
  );
drop policy if exists "statuses_insert_own" on statuses;
create policy "statuses_insert_own" on statuses for insert to authenticated
  with check (profile_id = my_profile_id());
drop policy if exists "statuses_delete_own" on statuses;
create policy "statuses_delete_own" on statuses for delete
  using (profile_id = my_profile_id());

-- status_comments: anyone who can see the status (owner, admin, or an
-- active subscriber while it hasn't expired) can post a comment on it,
-- but only the status owner (or admin) can read the comment thread back —
-- comments are effectively private feedback to the poster, not a public
-- thread. A comment can be removed by whoever wrote it, the post's owner
-- (moderation on your own post), or admin.
alter table status_comments enable row level security;
drop policy if exists "status_comments_select_if_status_visible" on status_comments;
create policy "status_comments_select_owner_or_admin" on status_comments for select
  using (
    is_admin()
    or exists (
      select 1 from statuses s
      where s.id = status_comments.status_id
        and s.profile_id = my_profile_id()
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
  );
drop policy if exists "status_comments_delete_own_or_post_owner" on status_comments;
create policy "status_comments_delete_own_or_post_owner" on status_comments for delete
  using (
    profile_id = my_profile_id()
    or is_admin()
    or exists (select 1 from statuses s where s.id = status_comments.status_id and s.profile_id = my_profile_id())
  );

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
end $$;
