// ============================================================
// new+ shared helpers
// ============================================================

function initSupabase() {
  const root = document.getElementById("app");
  try {
    if (typeof window.supabase === "undefined") {
      throw new Error("Supabase library did not load. Check your internet connection and refresh.");
    }
    if (!SUPABASE_URL || SUPABASE_URL.includes("PASTE_") || !SUPABASE_ANON_KEY || SUPABASE_ANON_KEY.includes("PASTE_")) {
      throw new Error("config.js is not set up yet. Open config.js and paste in your Supabase Project URL and anon key (see SETUP_GUIDE.md, step 3).");
    }
    return window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  } catch (err) {
    // This one deliberately does NOT use showToast/auto-dismiss: it means
    // the app never loaded at all, so there's no working screen to return
    // to once a timer fires. It should stay on screen until the person
    // fixes the underlying problem and refreshes.
    root.innerHTML = `
      <div class="brand">new<span class="plus">+</span></div>
      <div class="error-banner"><strong>Couldn't start the app.</strong><br>${err.message}</div>`;
    throw err;
  }
}

async function ensureSession(sb) {
  const { data: { session } } = await sb.auth.getSession();
  if (session) return session;
  const { data, error } = await sb.auth.signInAnonymously();
  if (error) {
    throw new Error(
      "Couldn't start a session (" + error.message + "). " +
      "Make sure Anonymous Sign-ins are enabled in Supabase " +
      "(Authentication → Sign In / Providers), see SETUP_GUIDE.md step 4."
    );
  }
  return data.session;
}

// Any error thrown inside a render function now shows as an auto-dismissing
// toast (see showToast below) instead of a banner permanently appended to
// #app. Previously these never went away on their own — they only
// disappeared if/when the screen re-rendered.
function safeRender(fn) {
  return async (...args) => {
    try {
      await fn(...args);
    } catch (err) {
      console.error(err);
      showToast(err.message || String(err));
    }
  };
}

function initials(name) {
  if (!name) return "?";
  return name.trim().split(/\s+/).slice(0, 2).map(w => w[0].toUpperCase()).join("");
}

function timeAgo(iso) {
  const d = new Date(iso);
  const diffMs = Date.now() - d.getTime();
  const mins = Math.floor(diffMs / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  return `${days}d ago`;
}

function ageFromDob(dob) {
  if (!dob) return null;
  const d = new Date(dob);
  const diff = Date.now() - d.getTime();
  return Math.floor(diff / (365.25 * 24 * 60 * 60 * 1000));
}

// Great-circle distance in km between two lat/lng points.
function distanceKm(lat1, lng1, lat2, lng2) {
  if (lat1 == null || lng1 == null || lat2 == null || lng2 == null) return null;
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLng = (lng2 - lng1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function escapeHtml(str) {
  const d = document.createElement("div");
  d.textContent = str ?? "";
  // textContent -> innerHTML encodes <, >, and & but NOT quote characters
  // (quotes are only special in attribute-value serialization, not text
  // nodes). Encode them too so this is safe to drop into a "..." attribute
  // (e.g. data-image-path="${escapeHtml(x)}"), not just into element text.
  return d.innerHTML.replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

// ============================================================
// Non-blocking replacement for window.alert(). Native alert() dialogs are
// disruptive and, worse, browsers like Safari offer a "Suppress dialogs"
// button after a couple of them fire — if a user taps that by accident,
// EVERY future alert() on the page (including important ones later) goes
// silently missing for the rest of that tab session. This shows the same
// message as an in-page banner instead: non-blocking, dismissible, and
// impossible to accidentally silence.
//
// Auto-dismiss duration: 3 seconds is enough time to actually read a
// short message like "Wrong phone number or PIN" without it lingering on
// screen indefinitely. Callers can still override via opts.duration
// (e.g. showToast(msg, { duration: 0 }) to keep it up until dismissed
// by hand), and the dismiss (✕) button always works immediately either way.
// ============================================================
function showToast(message, opts = {}) {
  const duration = opts.duration ?? 3000;
  let container = document.getElementById("global-toast");
  if (!container) {
    container = document.createElement("div");
    container.id = "global-toast";
    container.className = "global-toast";
    document.body.appendChild(container);
  }
  clearTimeout(container._dismissTimer);
  container.innerHTML = `<div class="error-banner">
    <span>${escapeHtml(message)}</span>
    <button type="button" class="error-banner-dismiss" aria-label="Dismiss" onclick="document.getElementById('global-toast').innerHTML=''">✕</button>
  </div>`;
  if (duration) {
    container._dismissTimer = setTimeout(() => {
      if (container.isConnected) container.innerHTML = "";
    }, duration);
  }
}

function friendlyError(error) {
  const msg = error?.message || String(error);
  if (msg.includes("phone_taken")) return "That phone number is already registered. Try logging in instead.";
  if (msg.includes("invalid_credentials")) return "Wrong phone number or PIN.";
  if (msg.includes("too_many_attempts")) return "Too many wrong PIN attempts. Please wait a few minutes and try again.";
  if (msg.includes("must_be_18")) return "You must be 18 or older to use new+.";
  if (msg.includes("account_deactivated")) return "This account has been deactivated. Contact support if you think this is a mistake.";
  if (msg.includes("no active session")) return "Your session expired — please refresh the page and try again.";
  if (msg.includes("subscription_inactive")) return "Your subscription isn't active — subscribe to keep chatting.";
  if (msg.includes("phone_not_found")) return "We couldn't find an account with that phone number.";
  if (msg.includes("invalid_pin_format")) return "PIN must be exactly 4 digits.";
  if (msg.includes("no_reset_pending")) return "There's no pending PIN reset on this account.";
  return msg;
}

// Wraps a Supabase Storage upload with automatic retries. Uploads can fail
// transiently on flaky mobile connections (e.g. Safari's generic
// "TypeError: Load failed" when a fetch drops mid-request) — retrying a
// couple of times with a short delay clears most of those without the
// person ever seeing an error or having to resend anything themselves.
async function uploadWithRetry(sb, bucket, path, fileOrBlob, options, maxRetries = 2) {
  let lastError = null;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    const { error } = await sb.storage.from(bucket).upload(path, fileOrBlob, options);
    if (!error) return { error: null };
    lastError = error;
    if (attempt < maxRetries) await new Promise(r => setTimeout(r, 800 * (attempt + 1)));
  }
  return { error: lastError };
}
// uploads stay small and fast even on slow mobile connections.
function compressImage(file, maxDim = 820, quality = 0.62) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    const reader = new FileReader();
    reader.onload = () => { img.src = reader.result; };
    reader.onerror = reject;
    img.onload = () => {
      let { width, height } = img;
      if (width > maxDim || height > maxDim) {
        if (width > height) { height = Math.round(height * (maxDim / width)); width = maxDim; }
        else { width = Math.round(width * (maxDim / height)); height = maxDim; }
      }
      const canvas = document.createElement("canvas");
      canvas.width = width; canvas.height = height;
      canvas.getContext("2d").drawImage(img, 0, 0, width, height);
      canvas.toBlob(blob => blob ? resolve(blob) : reject(new Error("Couldn't process image")), "image/jpeg", quality);
    };
    img.onerror = reject;
    reader.readAsDataURL(file);
  });
}

// ============================================================
// Discourage casual view-source / devtools access.
// NOTE: this is NOT real security — anyone determined can still get to
// page source via the browser's Network tab or dev tools menu. It only
// blocks the easy shortcuts (right-click, F12, Ctrl+U, etc.) so casual
// users don't stumble into it by accident.
// ============================================================
document.addEventListener("contextmenu", (e) => e.preventDefault());

// ============================================================
// Block double-tap-to-zoom.
// The `touch-action: manipulation` rule in style.css handles this in most
// browsers, but some mobile browsers (older iOS Safari, some Android
// WebViews) still zoom on a fast double-tap despite that CSS property.
// This is a belt-and-braces JS fallback: if two touchend events land
// within 350ms of each other, the second one's default action (zoom)
// is cancelled. Doesn't affect normal typing/scrolling/single taps.
// ============================================================
let lastTouchEnd = 0;
document.addEventListener("touchend", (e) => {
  const now = Date.now();
  if (now - lastTouchEnd <= 350) {
    e.preventDefault();
  }
  lastTouchEnd = now;
}, { passive: false });

document.addEventListener("keydown", (e) => {
  const key = e.key.toUpperCase();
  const blocked =
    e.key === "F12" ||
    (e.ctrlKey && e.shiftKey && (key === "I" || key === "J" || key === "C")) || // devtools
    (e.ctrlKey && key === "U") || // view-source
    (e.metaKey && e.altKey && key === "I"); // Mac devtools
  if (blocked) e.preventDefault();
});
