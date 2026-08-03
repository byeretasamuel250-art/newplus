// ============================================================
// pesapal-ipn — Supabase Edge Function
//
// This is the public webhook Pesapal calls whenever a payment's status
// changes. Deploy it, then register its URL with Pesapal ONCE (next step
// in SETUP_GUIDE.md) to get an IPN ID — that ID is what pesapal-order
// uses when it creates a payment.
//
// Deploy with:  supabase functions deploy pesapal-ipn --no-verify-jwt
//   (--no-verify-jwt is required: Pesapal calls this directly, with no
//   Supabase auth token attached)
//
// Secrets needed (set once, see SETUP_GUIDE.md):
//   supabase secrets set PESAPAL_CONSUMER_KEY=...
//   supabase secrets set PESAPAL_CONSUMER_SECRET=...
//   supabase secrets set PESAPAL_ENV=sandbox   (switch to "live" once your Pesapal KYC/contract is approved)
//   (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically)
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CONSUMER_KEY = Deno.env.get("PESAPAL_CONSUMER_KEY")!;
const CONSUMER_SECRET = Deno.env.get("PESAPAL_CONSUMER_SECRET")!;
const PESAPAL_ENV = Deno.env.get("PESAPAL_ENV") || "sandbox";

// Sandbox = test mode (no real money moves). Live = real payments, only
// works once your Pesapal contract/KYC is approved.
const BASE_URL = PESAPAL_ENV === "live"
  ? "https://pay.pesapal.com/v3"
  : "https://cybqa.pesapal.com/pesapalv3";

const sb = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

async function getPesapalToken(): Promise<string> {
  const res = await fetch(`${BASE_URL}/api/Auth/RequestToken`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Accept": "application/json" },
    body: JSON.stringify({ consumer_key: CONSUMER_KEY, consumer_secret: CONSUMER_SECRET }),
  });
  const data = await res.json();
  if (!data.token) throw new Error("Pesapal auth failed: " + JSON.stringify(data));
  return data.token;
}

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    let trackingId = url.searchParams.get("OrderTrackingId") || url.searchParams.get("orderTrackingId");
    let merchantRef = url.searchParams.get("OrderMerchantReference") || url.searchParams.get("orderMerchantReference");
    let notificationType = url.searchParams.get("OrderNotificationType") || url.searchParams.get("orderNotificationType") || "IPNCHANGE";

    // Depending on how the IPN is registered, Pesapal may POST a JSON body instead of using query params.
    if (!trackingId && req.method === "POST") {
      const body = await req.json().catch(() => ({}));
      trackingId = body.OrderTrackingId || body.orderTrackingId;
      merchantRef = body.OrderMerchantReference || body.orderMerchantReference;
      notificationType = body.OrderNotificationType || body.orderNotificationType || notificationType;
    }

    if (!trackingId) {
      return new Response("missing OrderTrackingId", { status: 200 });
    }

    // Don't trust the notification alone — ask Pesapal directly what the real status is.
    const token = await getPesapalToken();
    const statusRes = await fetch(
      `${BASE_URL}/api/Transactions/GetTransactionStatus?orderTrackingId=${encodeURIComponent(trackingId)}`,
      { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } }
    );
    const statusData = await statusRes.json();
    const description = (statusData.payment_status_description || "").toUpperCase();

    const { data: reqRow } = await sb
      .from("subscription_requests")
      .select("id, profile_id")
      .eq("merchant_reference", merchantRef)
      .maybeSingle();

    if (reqRow) {
      if (description === "COMPLETED") {
        const expires = new Date();
        expires.setDate(expires.getDate() + 30);
        await sb.from("subscription_requests")
          .update({ status: "approved", pesapal_tracking_id: trackingId })
          .eq("id", reqRow.id);
        await sb.from("profiles")
          .update({ subscription_status: "active", subscription_expires_at: expires.toISOString() })
          .eq("id", reqRow.profile_id);
      } else if (description === "FAILED" || description === "INVALID") {
        await sb.from("subscription_requests")
          .update({ status: "rejected", pesapal_tracking_id: trackingId })
          .eq("id", reqRow.id);
      }
      // Anything else (e.g. "PENDING") — leave it alone, Pesapal will call again on the next change.
    }

    // Pesapal requires this exact confirmation shape back, or it will keep retrying.
    return new Response(JSON.stringify({
      orderNotificationType: notificationType,
      orderTrackingId: trackingId,
      orderMerchantReference: merchantRef,
      status: 200,
    }), { headers: { "Content-Type": "application/json" }, status: 200 });
  } catch (err) {
    console.error(err);
    return new Response(String(err), { status: 500 });
  }
});
