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
//   supabase secrets set PESAPAL_CONSUMER_KEY=...        (YOUR real merchant key, used only when PESAPAL_ENV=live)
//   supabase secrets set PESAPAL_CONSUMER_SECRET=...     (YOUR real merchant secret, used only when PESAPAL_ENV=live)
//   supabase secrets set PESAPAL_ENV=sandbox   (switch to "live" once your Pesapal KYC/contract is approved)
//   (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically)
//
// Sandbox testing uses Pesapal's shared public demo credentials (not your
// real ones — sandbox and live are separate systems with separate keys),
// so no extra secret is needed to test.
//
// ------------------------------------------------------------
// SECURITY FIX (see security review): this endpoint is public — anyone
// can POST to it with any OrderTrackingId / OrderMerchantReference they
// like, since Pesapal calls it with no auth token. The code below always
// re-verifies the REAL status of a tracking ID directly with Pesapal, so
// a caller can never fake "COMPLETED" for a payment that didn't happen.
//
// But the row to update must ALSO be found using something Pesapal
// itself vouches for — never the caller-supplied merchant reference.
// Previously this looked the row up by `merchant_reference` taken
// straight from the request, which let someone pair ONE real completed
// trackingId with ANY OTHER pending merchant_reference they happened to
// know (e.g. one of their own other, unpaid accounts) and get it
// approved for free. It now looks the row up by `pesapal_tracking_id`
// instead — a value that was (a) written to the database by
// pesapal-order at order-creation time, before any payment happened, and
// (b) is exactly the trackingId whose status we just verified with
// Pesapal — so there's no longer any caller-controlled input in the
// lookup itself.
// ------------------------------------------------------------
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PESAPAL_ENV = Deno.env.get("PESAPAL_ENV") || "sandbox";

// Sandbox = test mode (no real money moves, uses Pesapal's shared public
// demo credentials for Uganda). Live = your real account, real payments —
// only works once your Pesapal contract/KYC is approved.
const CONSUMER_KEY = PESAPAL_ENV === "live"
  ? Deno.env.get("PESAPAL_CONSUMER_KEY")!
  : "TDpigBOOhs+zAl8cwH2Fl82jJGyD8xev";
const CONSUMER_SECRET = PESAPAL_ENV === "live"
  ? Deno.env.get("PESAPAL_CONSUMER_SECRET")!
  : "1KpqkfsMaihIcOlhnBo/gBZ5smw=";

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
    // This call is the ONLY source of truth for `description` below — a caller
    // can never make this say "COMPLETED" for a trackingId that wasn't really paid.
    const token = await getPesapalToken();
    const statusRes = await fetch(
      `${BASE_URL}/api/Transactions/GetTransactionStatus?orderTrackingId=${encodeURIComponent(trackingId)}`,
      { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } }
    );
    const statusData = await statusRes.json();
    const description = (statusData.payment_status_description || "").toUpperCase();

    // IMPORTANT: look the row up by pesapal_tracking_id — a value we
    // ourselves wrote to the database when the order was created, and
    // which is exactly the trackingId whose status Pesapal just verified
    // above. Never look this up by the caller-supplied merchantRef; that
    // field is only used below to echo back Pesapal's required
    // confirmation shape, never to decide which row gets approved.
    const { data: reqRow } = await sb
      .from("subscription_requests")
      .select("id, profile_id")
      .eq("pesapal_tracking_id", trackingId)
      .maybeSingle();

    if (reqRow) {
      if (description === "COMPLETED") {
        const expires = new Date();
        expires.setDate(expires.getDate() + 30);
        const { error: reqUpdateErr } = await sb.from("subscription_requests")
          .update({ status: "approved" })
          .eq("id", reqRow.id);
        if (reqUpdateErr) console.error("Failed to update subscription_requests:", reqUpdateErr);

        const { error: profileUpdateErr } = await sb.from("profiles")
          .update({ subscription_status: "active", subscription_expires_at: expires.toISOString() })
          .eq("id", reqRow.profile_id);
        if (profileUpdateErr) console.error("Failed to activate profile subscription:", profileUpdateErr);
      } else if (description === "FAILED" || description === "INVALID") {
        const { error: rejectErr } = await sb.from("subscription_requests")
          .update({ status: "rejected" })
          .eq("id", reqRow.id);
        if (rejectErr) console.error("Failed to update subscription_requests:", rejectErr);
      }
      // Anything else (e.g. "PENDING") — leave it alone, Pesapal will call again on the next change.
    }

    // Pesapal requires this exact confirmation shape back, or it will keep retrying.
    // Echoing back the caller's own merchantRef/notificationType here is fine — it's
    // just satisfying Pesapal's expected response shape, not used for any decision above.
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
