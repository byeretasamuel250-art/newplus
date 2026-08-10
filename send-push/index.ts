// ============================================================
// send-push — Supabase Edge Function
//
// Triggered by a Database trigger (see schema.sql) on INSERT into
// `messages` and `notifications`. Looks up the recipient's push
// subscriptions and sends a Web Push notification via VAPID, including
// an unread-count badge so installed PWAs (Android/Chrome) show a
// number on the icon.
//
// Deploy with:  supabase functions deploy send-push
// Secrets needed (set once, see SETUP_GUIDE.md):
//   supabase secrets set VAPID_PUBLIC_KEY=...
//   supabase secrets set VAPID_PRIVATE_KEY=...
//   supabase secrets set VAPID_SUBJECT=mailto:you@example.com
//   supabase secrets set PUSH_TRIGGER_SECRET=...   (see SECURITY FIX note below)
//   (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically)
//
// ------------------------------------------------------------
// SECURITY FIX (see security review): this function used to trust
// whatever {table, record} JSON it was sent, with no check on WHO sent
// it. The DB trigger calls it using the public anon/publishable key —
// the same key that's already public in config.js — so anyone who found
// this function's URL (e.g. in your GitHub repo, or by guessing the
// standard Supabase functions URL pattern) could POST a crafted body
// directly and make a real push notification — with an attacker-chosen
// title/body, or a spoofed "X liked your status" — land on any real
// user's device, without any matching message/notification ever having
// been created.
//
// Fix: require a shared secret that only the DB trigger knows (set as a
// Postgres setting AND an edge function secret — see the updated
// notify_send_push() trigger in schema.sql). Any request missing or
// mismatching it is rejected before touching the database or sending
// anything.
//
// THIS IS THE FILE THAT MUST BE DEPLOYED — an older copy of this
// function without the X-Internal-Secret check is still floating around;
// if that one is what's live, this protection isn't actually active yet.
// Also make sure both of these are set to the SAME value, or every
// request will be rejected (push just silently stops working, nothing
// breaks loudly):
//   1. Edge function secret:  supabase secrets set PUSH_TRIGGER_SECRET=<value>
//   2. Postgres setting (SQL Editor, with the SAME value):
//      alter database postgres set app.settings.push_trigger_secret = '<value>';
// ------------------------------------------------------------
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "https://esm.sh/web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") || "mailto:admin@newplus.app";
const PUSH_TRIGGER_SECRET = Deno.env.get("PUSH_TRIGGER_SECRET");

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

const sb = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

Deno.serve(async (req) => {
  try {
    // Reject anything that doesn't carry the secret only the DB trigger
    // knows. If PUSH_TRIGGER_SECRET hasn't been set yet (e.g. mid-upgrade),
    // fail closed rather than silently accepting unauthenticated calls.
    const suppliedSecret = req.headers.get("X-Internal-Secret");
    if (!PUSH_TRIGGER_SECRET || suppliedSecret !== PUSH_TRIGGER_SECRET) {
      return new Response("forbidden", { status: 403 });
    }

    const payload = await req.json();
    // Database trigger payload shape: { type: "INSERT", table, record, ... }
    const table = payload.table;
    const record = payload.record;
    if (!record) return new Response("no record", { status: 200 });

    let recipientId: string | null = null;
    let title = "newplus";
    let body = "You have a new notification";

    if (table === "messages") {
      // Figure out the OTHER participant in the conversation — that's who gets notified.
      const { data: convo } = await sb
        .from("conversations")
        .select("user_a, user_b")
        .eq("id", record.conversation_id)
        .maybeSingle();
      if (!convo) return new Response("no conversation", { status: 200 });
      recipientId = convo.user_a === record.sender_id ? convo.user_b : convo.user_a;

      const { data: sender } = await sb
        .from("profiles")
        .select("name")
        .eq("id", record.sender_id)
        .maybeSingle();
      title = sender?.name || "New message";
      body =
        record.kind === "text"
          ? (record.body?.slice(0, 120) || "New message")
          : record.kind === "image"
          ? "📷 Sent a photo"
          : record.kind === "voice"
          ? "🎤 Sent a voice note"
          : "New message";
    } else if (table === "notifications") {
      recipientId = record.profile_id;
      const { data: actor } = await sb
        .from("profiles")
        .select("name")
        .eq("id", record.actor_id)
        .maybeSingle();
      const actorName = actor?.name || "Someone";
      if (record.type === "comment_reply") { title = "newplus"; body = `${actorName} replied to your comment`; }
      else if (record.type === "status_comment") { title = "newplus"; body = `${actorName} commented on your status`; }
      else if (record.type === "status_like") { title = "newplus"; body = `${actorName} liked your status`; }
    } else {
      return new Response("ignored table", { status: 200 });
    }

    if (!recipientId) return new Response("no recipient", { status: 200 });

    // Badge count: total unread messages across all conversations for this
    // recipient, via a service-role-friendly SQL function (added in
    // schema.sql) since this function has no user session to rely on.
    let badgeCount = 0;
    const { data: unreadCount } = await sb.rpc("get_unread_count_for", { p_profile_id: recipientId });
    if (typeof unreadCount === "number") badgeCount = unreadCount;

    const { data: subs } = await sb
      .from("push_subscriptions")
      .select("endpoint, p256dh, auth")
      .eq("profile_id", recipientId);

    if (!subs || subs.length === 0) return new Response("no subscriptions", { status: 200 });

    const notificationPayload = JSON.stringify({ title, body, badge: badgeCount, url: "/" });

    const results = await Promise.allSettled(
      subs.map((s) =>
        webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          notificationPayload
        )
      )
    );

    // Clean up subscriptions that are no longer valid (410 Gone / 404).
    for (let i = 0; i < results.length; i++) {
      const r = results[i];
      if (r.status === "rejected") {
        const statusCode = (r.reason as any)?.statusCode;
        if (statusCode === 404 || statusCode === 410) {
          await sb.from("push_subscriptions").delete().eq("endpoint", subs[i].endpoint);
        }
      }
    }

    return new Response("ok", { status: 200 });
  } catch (err) {
    console.error(err);
    return new Response(String(err), { status: 500 });
  }
});
