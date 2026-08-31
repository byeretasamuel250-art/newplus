-- ============================================================
-- Patch: authorize Realtime Broadcast channels
-- Run this in Supabase: Dashboard -> SQL Editor -> New query -> Run
-- (after schema.sql; requires my_profile_id() and is_active_subscriber(),
-- both defined there)
-- ------------------------------------------------------------
-- Three channels carry Broadcast events with no channel-level access
-- control today: anyone holding the public anon key could open a
-- websocket and subscribe directly, bypassing every RLS rule already
-- enforced everywhere else in this schema.
--
--   1. "directory-updates"     — bypasses the subscription paywall:
--      is_active_subscriber() gates get_directory(), but nothing
--      gated who could listen for live profile changes on this
--      channel.
--   2. "global-messages-<id>"  — leaks who's messaging whom: anyone
--      who knows/discovers a profile's id (both get_directory() and
--      get_public_profiles() hand these out) could listen for that
--      person's incoming-message events without being a participant.
--   3. "conversation-<id>"     — the typing/stopped_typing broadcast
--      events on this channel were similarly unguarded (lower
--      severity: conversation ids aren't practically guessable, and
--      only a typing indicator, not message content, is exposed).
--
-- Fix: enable RLS on realtime.messages (Supabase's Realtime
-- Authorization table) and add policies scoped exactly to who should
-- be able to receive (and, for the conversation channel, send) each
-- topic's broadcasts.
--
-- IMPORTANT: this is only HALF the fix. The matching client-side
-- change (`config: { private: true }` on each channel, plus wiring
-- the session JWT into sb.realtime via sb.realtime.setAuth()) is
-- required too — see index.html / shared.js. A private channel with
-- no policy denies everyone; a channel left public ignores these
-- policies entirely and stays exactly as open as before. Both halves
-- must ship together, or realtime features on the affected channels
-- will either silently stop working (private + no client change) or
-- stay silently unprotected (client change + no policy).
-- ============================================================

alter table realtime.messages enable row level security;

-- ---------- directory-updates ----------
-- Sent only by broadcast_directory_change() (security definer — its
-- own INSERT into realtime.messages always bypasses RLS regardless of
-- policies here, since it runs as the function owner). This channel
-- only ever needs a SELECT policy, for receiving.
drop policy if exists "directory_updates_select_active_subscriber" on realtime.messages;
create policy "directory_updates_select_active_subscriber"
  on realtime.messages for select
  to authenticated
  using (
    realtime.topic() = 'directory-updates'
    and is_active_subscriber()
  );

-- ---------- global-messages-<profile_id> ----------
-- Sent only by broadcast_new_message() (security definer, same
-- reasoning as above) — only needs a SELECT policy. The topic is
-- compared as one whole string built from my_profile_id(), never
-- parsed or cast out of the topic, so there's no ambiguity and no
-- risk of a malformed-input error.
drop policy if exists "global_messages_select_own" on realtime.messages;
create policy "global_messages_select_own"
  on realtime.messages for select
  to authenticated
  using (
    realtime.topic() = 'global-messages-' || my_profile_id()::text
  );

-- ---------- conversation-<id> (typing / stopped_typing broadcasts) ----------
-- Unlike the two above, these ARE sent directly by a participant's own
-- browser (state.messagesChannel.send(...) in index.html), so this
-- topic needs both a SELECT policy (to receive) and an INSERT policy
-- (to send), both scoped to the two participants of that
-- conversation.
--
-- This helper function exists (rather than inlining the check into
-- each policy) specifically to avoid a subtle bug: Postgres does not
-- guarantee left-to-right short-circuit evaluation of AND-chained
-- conditions in a policy — an inline "topic like 'conversation-%' and
-- topic_suffix::uuid = ..." could still have its ::uuid cast evaluated
-- on a topic that doesn't match the prefix (e.g. 'directory-updates'),
-- which would throw a cast error instead of just denying access. This
-- function checks the shape with a regex first and wraps the cast in
-- an exception handler, so any topic that isn't a well-formed
-- "conversation-<uuid>" string safely returns false rather than
-- erroring — postgres_changes events on this same channel (new
-- messages, edits, deletes, read receipts) are untouched by any of
-- this either way, since those already enforce RLS on the underlying
-- tables independent of channel privacy.
create or replace function realtime_topic_is_conversation_participant()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  convo_id uuid;
begin
  if realtime.topic() !~ '^conversation-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return false;
  end if;
  convo_id := substring(realtime.topic() from 'conversation-(.*)')::uuid;
  return exists (
    select 1 from conversations c
    where c.id = convo_id
      and (c.user_a = my_profile_id() or c.user_b = my_profile_id())
  );
exception when others then
  -- Any unexpected parsing/casting problem denies access rather than
  -- erroring the whole request — fail closed, never fail loud.
  return false;
end;
$$;
grant execute on function realtime_topic_is_conversation_participant() to authenticated;

drop policy if exists "conversation_typing_select_participant" on realtime.messages;
create policy "conversation_typing_select_participant"
  on realtime.messages for select
  to authenticated
  using ( realtime_topic_is_conversation_participant() );

drop policy if exists "conversation_typing_insert_participant" on realtime.messages;
create policy "conversation_typing_insert_participant"
  on realtime.messages for insert
  to authenticated
  with check ( realtime_topic_is_conversation_participant() );
