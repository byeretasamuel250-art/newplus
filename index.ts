// ============================================================
// send-pin-reset-email — Supabase Edge Function
//
// Called directly (not via a DB trigger) by request_pin_reset_email(),
// via pg_net — the same pattern send-push uses to reach its own edge
// function. Sends the 6-digit PIN reset code to the user's email via
// Resend (https://resend.com).
//
// Deploy with:  supabase functions deploy send-pin-reset-email
// Secrets needed (set once, see SETUP_GUIDE.md):
//   supabase secrets set RESEND_API_KEY=...
//   supabase secrets set PIN_RESET_TRIGGER_SECRET=...
//   supabase secrets set RESEND_FROM_ADDRESS='newplus <you@yourdomain.com>'   (optional)
//
// ------------------------------------------------------------
// SECURITY: same shape as send-push's X-Internal-Secret check. This
// function must reject any request that doesn't carry the shared
// secret — the DB function calls it with a secret set as a Postgres
// setting (app.settings.pin_reset_trigger_secret), which must match
// PIN_RESET_TRIGGER_SECRET set here. Without this check, anyone with
// the public anon key could POST a crafted body straight to this
// function's URL and make it send arbitrary email (including a
// phishing "PIN reset code") from your Resend account/domain to any
// address they choose.
// ------------------------------------------------------------
// ============================================================

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
const PIN_RESET_TRIGGER_SECRET = Deno.env.get("PIN_RESET_TRIGGER_SECRET");
const FROM_ADDRESS = Deno.env.get("RESEND_FROM_ADDRESS") || "newplus <onboarding@resend.dev>";

function escapeHtml(str: string) {
  return String(str ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

Deno.serve(async (req) => {
  try {
    const suppliedSecret = req.headers.get("X-Internal-Secret");
    if (!PIN_RESET_TRIGGER_SECRET || suppliedSecret !== PIN_RESET_TRIGGER_SECRET) {
      return new Response("forbidden", { status: 403 });
    }

    const payload = await req.json();
    const email: string | undefined = payload?.email;
    const code: string | undefined = payload?.code;
    const name: string | undefined = payload?.name;

    if (!email || !code) {
      return new Response("missing email or code", { status: 400 });
    }

    const safeName = name ? escapeHtml(name) : null;
    const greeting = safeName ? `Hi ${safeName},` : "Hi,";
    const safeCode = escapeHtml(code);

    const html = `
      <div style="font-family:sans-serif;max-width:480px;margin:0 auto;color:#1a1a1a">
        <p>${greeting}</p>
        <p>Your newplus PIN reset code is:</p>
        <p style="font-size:32px;font-weight:700;letter-spacing:6px;margin:16px 0">${safeCode}</p>
        <p>This code expires in 15 minutes and can only be used once.</p>
        <p>If you didn't request this, you can safely ignore this email — your PIN will not change.</p>
      </div>
    `;

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: FROM_ADDRESS,
        to: [email],
        subject: "Your newplus PIN reset code",
        html,
      }),
    });

    if (!res.ok) {
      const errText = await res.text();
      console.error("Resend error:", res.status, errText);
      return new Response("email send failed", { status: 502 });
    }

    return new Response("ok", { status: 200 });
  } catch (err) {
    console.error(err);
    return new Response(String(err), { status: 500 });
  }
});
