// ============================================================
// send-push — Supabase Edge Function
//
// Triggered by a Database Webhook on INSERT to `messages` and
// `notifications` (see SETUP_GUIDE.md for how to wire that up). Looks
// up who should be notified, fetches their push_subscriptions rows,
// and sends each one an actual Web Push message via VAPID.
//
// This is the one piece of newplus that isn't just static files +
// Supabase — Web Push requires a server to hold the VAPID private key
// and talk to the browser's push service, and that can't happen from
// the client. Deploy with: supabase functions deploy send-push
// ============================================================

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY")!;
const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY")!;
const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "mailto:admin@example.com";
// Shared secret the database webhook sends as a header, so this endpoint
// can't be spammed by someone who finds the URL. Set the same value in
// both the function's secrets and the webhook's custom header.
const webhookSecret = Deno.env.get("WEBHOOK_SECRET");

webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);
const sb = createClient(supabaseUrl, serviceRoleKey);

function notificationText(type: string): string {
  if (type === "status_comment") return "commented on your post";
  if (type === "status_like") return "liked your post";
  return "replied to your comment";
}

Deno.serve(async (req) => {
  if (webhookSecret && req.headers.get("x-webhook-secret") !== webhookSecret) {
    return new Response("unauthorized", { status: 401 });
  }

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return new Response("bad request", { status: 400 });
  }

  const { table, record } = payload || {};
  if (!record) return new Response("ok");

  let recipientId: string | null = null;
  let title = "newplus";
  let body = "";
  let tag: string | undefined;

  if (table === "messages") {
    const { data: convo } = await sb.from("conversations")
      .select("user_a, user_b").eq("id", record.conversation_id).maybeSingle();
    if (!convo) return new Response("ok");
    recipientId = convo.user_a === record.sender_id ? convo.user_b : convo.user_a;
    if (!recipientId || recipientId === record.sender_id) return new Response("ok");

    const { data: sender } = await sb.from("profiles").select("name").eq("id", record.sender_id).maybeSingle();
    title = sender?.name || "New message";
    body = record.kind === "text" ? String(record.body || "").slice(0, 120)
      : record.kind === "image" ? "Sent a photo"
      : record.kind === "voice" ? "Sent a voice note"
      : "Sent you a message";
    tag = "conversation-" + record.conversation_id;

  } else if (table === "notifications") {
    recipientId = record.profile_id;
    const { data: actor } = await sb.from("profiles").select("name").eq("id", record.actor_id).maybeSingle();
    body = `${actor?.name || "Someone"} ${notificationText(record.type)}`;
    tag = "notification-" + record.id;

  } else {
    return new Response("ignored table", { status: 200 });
  }

  if (!recipientId) return new Response("ok");

  const { data: subs } = await sb.from("push_subscriptions").select("*").eq("profile_id", recipientId);
  if (!subs || !subs.length) return new Response("ok");

  const pushPayload = JSON.stringify({ title, body, url: "/", tag });

  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        pushPayload
      );
    } catch (err: any) {
      // 404/410 means the browser dropped this subscription (uninstalled,
      // cleared data, etc) — clean it up so we stop trying.
      if (err?.statusCode === 404 || err?.statusCode === 410) {
        await sb.from("push_subscriptions").delete().eq("id", s.id);
      } else {
        console.error("push send failed for subscription", s.id, err?.statusCode, err?.body);
      }
    }
  }));

  return new Response("ok", { status: 200 });
});
