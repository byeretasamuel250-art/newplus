// ============================================================
// pesapal-order — Supabase Edge Function
//
// Called by the app (from a logged-in user's browser) when they tap
// "Subscribe". Verifies who they are, records a pending payment request,
// asks Pesapal to create an order, and returns a redirect_url — the app
// sends the browser there so the user can pay.
//
// Deploy with:  supabase functions deploy pesapal-order
//   (no --no-verify-jwt here — unlike pesapal-ipn, this one is only ever
//   called by your own logged-in users, so Supabase's normal auth check
//   stays on)
//
// Secrets needed (see SETUP_GUIDE.md):
//   supabase secrets set PESAPAL_CONSUMER_KEY=...     (YOUR real merchant key, used only when PESAPAL_ENV=live)
//   supabase secrets set PESAPAL_CONSUMER_SECRET=...  (YOUR real merchant secret, used only when PESAPAL_ENV=live)
//   supabase secrets set PESAPAL_ENV=sandbox          (switch to "live" once your Pesapal contract/KYC is approved)
//   supabase secrets set PESAPAL_IPN_ID=...           (from registering pesapal-ipn's URL — see SETUP_GUIDE.md)
//   (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically)
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PESAPAL_ENV = Deno.env.get("PESAPAL_ENV") || "sandbox";
const PESAPAL_IPN_ID = Deno.env.get("PESAPAL_IPN_ID")!;

// Sandbox = test mode, uses Pesapal's shared public demo credentials for
// Uganda (not your real ones). Live = your real account, real payments.
const CONSUMER_KEY = PESAPAL_ENV === "live"
  ? Deno.env.get("PESAPAL_CONSUMER_KEY")!
  : "TDpigBOOhs+zAl8cwH2Fl82jJGyD8xev";
const CONSUMER_SECRET = PESAPAL_ENV === "live"
  ? Deno.env.get("PESAPAL_CONSUMER_SECRET")!
  : "1KpqkfsMaihIcOlhnBo/gBZ5smw=";

const BASE_URL = PESAPAL_ENV === "live"
  ? "https://pay.pesapal.com/v3"
  : "https://cybqa.pesapal.com/pesapalv3";

// Where Pesapal sends the user's browser back to after they pay (or cancel).
const CALLBACK_URL = "https://newplus.app/payment-complete.html";

const SUBSCRIPTION_AMOUNT = 2000; // UGX, matches the existing manual flow

const sb = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// Browsers block cross-origin calls unless the server explicitly allows
// them. Without these headers, the "Pay with Pesapal" button fails with a
// generic error before the request even reaches this code.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

async function getPesapalToken(): Promise<string> {
  const res = await fetch(`${BASE_URL}/api/Auth/RequestToken`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ consumer_key: CONSUMER_KEY, consumer_secret: CONSUMER_SECRET }),
  });
  const data = await res.json();
  if (!data.token) throw new Error("Pesapal auth failed: " + JSON.stringify(data));
  return data.token;
}

Deno.serve(async (req) => {
  // The browser sends a preflight OPTIONS request before the real one —
  // it must get a quick "yes, this is allowed" reply.
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Identify the caller from their Supabase session token (works for
    // anonymous sessions too — new+ has no email/password login).
    const jwt = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: userData, error: userErr } = await sb.auth.getUser(jwt);
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: "not_authenticated" }), { status: 401, headers: corsHeaders });
    }

    const { data: profile } = await sb
      .from("profiles")
      .select("id, name, phone")
      .eq("auth_uid", userData.user.id)
      .maybeSingle();
    if (!profile) {
      return new Response(JSON.stringify({ error: "no_profile" }), { status: 400, headers: corsHeaders });
    }

    // Mirrors the DB's one-pending-request-per-profile rule, but with a
    // self-healing twist: a Pesapal attempt that's more than 5 minutes old
    // almost certainly means the customer abandoned it (wrong PIN, no
    // wallet balance, closed the tab, etc.) rather than it still being in
    // progress — so we quietly clear it and let them try again, instead of
    // making them wait for an admin. A genuinely fresh pending request
    // (under 5 minutes) still blocks, to avoid two orders firing at once
    // if they tap the button twice. A stuck *manual* request still blocks
    // permanently — that one needs a human to actually check the payment.
    const { data: existingPending } = await sb
      .from("subscription_requests")
      .select("id, payment_method, created_at")
      .eq("profile_id", profile.id)
      .eq("status", "pending")
      .maybeSingle();
    if (existingPending) {
      const ageMs = Date.now() - new Date(existingPending.created_at).getTime();
      const isStalePesapal = existingPending.payment_method === "pesapal" && ageMs > 5 * 60 * 1000;
      if (isStalePesapal) {
        await sb.from("subscription_requests").update({ status: "rejected" }).eq("id", existingPending.id);
      } else {
        return new Response(JSON.stringify({ error: "already_pending" }), { status: 409, headers: corsHeaders });
      }
    }

    // Pesapal requires this reference to be 50 characters or fewer, using
    // only letters, numbers, dashes, underscores, dots, or colons — it does
    // NOT need to contain the profile ID, since the row itself already
    // links this reference back to the right profile.
    const merchantRef = `sub-${Date.now().toString(36)}-${crypto.randomUUID().replace(/-/g, "").slice(0, 8)}`;

    const { error: insertErr } = await sb.from("subscription_requests").insert({
      profile_id: profile.id,
      payment_method: "pesapal",
      merchant_reference: merchantRef,
      amount: SUBSCRIPTION_AMOUNT,
      status: "pending",
    });
    if (insertErr) throw insertErr;

    const token = await getPesapalToken();
    const orderRes = await fetch(`${BASE_URL}/api/Transactions/SubmitOrderRequest`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        id: merchantRef,
        currency: "UGX",
        amount: SUBSCRIPTION_AMOUNT,
        description: "newplus monthly subscription",
        callback_url: CALLBACK_URL,
        notification_id: PESAPAL_IPN_ID,
        billing_address: {
          phone_number: profile.phone || "",
          first_name: profile.name || "newplus",
          last_name: "user",
        },
      }),
    });
    const orderData = await orderRes.json();
    if (!orderData.redirect_url) {
      throw new Error("Pesapal order failed: " + JSON.stringify(orderData));
    }

    await sb.from("subscription_requests")
      .update({ pesapal_tracking_id: orderData.order_tracking_id })
      .eq("merchant_reference", merchantRef);

    return new Response(JSON.stringify({ redirect_url: orderData.redirect_url }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 500,
    });
  }
});
