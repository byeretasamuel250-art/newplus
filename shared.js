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

function safeRender(fn) {
  return async (...args) => {
    try {
      await fn(...args);
    } catch (err) {
      console.error(err);
      const root = document.getElementById("app");
      root.innerHTML += `<div class="error-banner"><strong>Something went wrong.</strong><br>${err.message || err}</div>`;
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

function friendlyError(error) {
  const msg = error?.message || String(error);
  if (msg.includes("phone_taken")) return "That phone number is already registered. Try logging in instead.";
  if (msg.includes("invalid_credentials")) return "Wrong phone number or PIN.";
  if (msg.includes("too_many_attempts")) return "Too many wrong PIN attempts. Please wait a few minutes and try again.";
  if (msg.includes("must_be_18")) return "You must be 18 or older to use new+.";
  if (msg.includes("account_deactivated")) return "This account has been deactivated. Contact support if you think this is a mistake.";
  if (msg.includes("no active session")) return "Your session expired — please refresh the page and try again.";
  if (msg.includes("subscription_inactive")) return "Your subscription isn't active — subscribe to keep chatting.";
  return msg;
}

// Resize + re-encode an image file client-side before upload, so photo
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
