// ============================================================
// new+ — send-push edge function
//
// Sends a Web Push notification when a new chat message or a new
// notification row (comment reply / status comment / status like) is
// inserted. Triggered by Supabase Database Webhooks — see
// SETUP_GUIDE.md for how to deploy this and wire the webhooks up.
//
// This function uses the service_role key, so it can read
// push_subscriptions (and everything else) regardless of RLS —
// that's why it lives here rather than in client code.
// ============================================================

import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com";
// Shared secret so random requests on the internet can't trigger pushes —
// the Database Webhook is configured to send this same header as a custom
// HTTP header. See SETUP_GUIDE.md.
const WEBHOOK_SECRET = Deno.env.get("PUSH_WEBHOOK_SECRET");

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

const sb = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

Deno.serve(async (req) => {
  if (WEBHOOK_SECRET && req.headers.get("x-webhook-secret") !== WEBHOOK_SECRET) {
    return new Response("unauthorized", { status: 401 });
  }

  const payload = await req.json().catch(() => null);
  if (!payload || !payload.table || !payload.record) {
    return new Response("bad payload", { status: 400 });
  }

  try {
    if (payload.table === "messages") {
      await handleMessage(payload.record);
    } else if (payload.table === "notifications") {
      await handleNotification(payload.record);
    }
  } catch (e) {
    console.error(e);
    return new Response("error: " + (e?.message ?? e), { status: 500 });
  }

  return new Response("ok");
});

async function handleMessage(message: any) {
  const { data: convo } = await sb
    .from("conversations")
    .select("user_a, user_b")
    .eq("id", message.conversation_id)
    .single();
  if (!convo) return;

  const recipientId = convo.user_a === message.sender_id ? convo.user_b : convo.user_a;

  const { data: sender } = await sb
    .from("profiles")
    .select("name")
    .eq("id", message.sender_id)
    .single();
  const senderName = sender?.name || "Someone";

  let body: string;
  if (message.kind === "image") body = "📷 Sent a photo";
  else if (message.kind === "voice") body = "🎤 Sent a voice note";
  else body = (message.body || "").slice(0, 120);

  await sendToProfile(recipientId, {
    title: senderName,
    body,
    tag: `conversation-${message.conversation_id}`,
    url: "/"
  });
}

async function handleNotification(notif: any) {
  const { data: actor } = await sb
    .from("profiles")
    .select("name")
    .eq("id", notif.actor_id)
    .single();
  const actorName = actor?.name || "Someone";

  const bodies: Record<string, string> = {
    comment_reply: `${actorName} replied to your comment`,
    status_comment: `${actorName} commented on your status`,
    status_like: `${actorName} liked your status`
  };

  await sendToProfile(notif.profile_id, {
    title: "new+",
    body: bodies[notif.type] || `${actorName} sent you a notification`,
    tag: `notification-${notif.id}`,
    url: "/"
  });
}

async function sendToProfile(profileId: string, notification: Record<string, string>) {
  const { data: subs } = await sb
    .from("push_subscriptions")
    .select("*")
    .eq("profile_id", profileId);
  if (!subs || subs.length === 0) return;

  await Promise.all(
    subs.map(async (sub: any) => {
      const pushSub = {
        endpoint: sub.endpoint,
        keys: { p256dh: sub.p256dh, auth: sub.auth }
      };
      try {
        await webpush.sendNotification(pushSub, JSON.stringify(notification));
      } catch (e: any) {
        // 404/410 = the browser/OS has permanently invalidated this
        // subscription (uninstalled, permission revoked, etc) — clean it up
        // so we stop trying to send to it.
        if (e?.statusCode === 404 || e?.statusCode === 410) {
          await sb.from("push_subscriptions").delete().eq("id", sub.id);
        } else {
          console.error("push send failed:", e?.statusCode, e?.body ?? e);
        }
      }
    })
  );
}
