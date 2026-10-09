/* Shared helpers for gateway pages. Loaded with a plain <script> tag before the page script. */

// Machine-specific values (serverName, lanIp) from /config.json, which Caddy builds from .env.
const configReady = (async () => {
  try {
    const r = await fetch("/config.json", { cache: "no-store" });
    if (r.ok) return await r.json();
  } catch {}
  return {};
})();

// server.tailXXXX.ts.net -> tailXXXX.ts.net
function tailnetOf(cfg) {
  return (cfg.serverName || location.hostname).split(".").slice(1).join(".");
}

// The app list from /apps.json with {tailnet} and {lan} filled in.
// Fields whose value needs {lan} are dropped when no LAN address is configured.
const appsReady = (async () => {
  const cfg = await configReady;
  let list = [];
  try {
    const r = await fetch("/apps.json", { cache: "no-store" });
    if (r.ok) list = await r.json();
  } catch {}
  const vars = { tailnet: tailnetOf(cfg), lan: cfg.lanIp || "" };
  return list.map(app => {
    const out = {};
    for (const [k, v] of Object.entries(app)) {
      if (typeof v !== "string") { out[k] = v; continue; }
      if (v.includes("{lan}") && !vars.lan) continue;
      out[k] = v.replace(/\{(tailnet|lan)\}/g, (_, name) => vars[name]);
    }
    return out;
  });
})();

// Authelia login state. Uses Authelia's internal API (/auth/api/*): re-test after upgrades.
// Resolves to { loggedIn, userName }.
const authReady = (async () => {
  try {
    const state = await fetch("/auth/api/state", { cache: "no-store" }).then(r => r.json());
    if (state?.data?.authentication_level > 0) {
      let userName = state.data.username || "";
      try {
        const info = await fetch("/auth/api/user/info", { cache: "no-store" }).then(r => r.json());
        userName = info?.data?.display_name || userName;
      } catch {}
      return { loggedIn: true, userName };
    }
  } catch {}
  return { loggedIn: false, userName: "" };
})();

// Login page; "rd" brings the user back afterwards.
function logIn(returnTo = location.origin + "/") {
  location.href = "/auth/?rd=" + encodeURIComponent(returnTo);
}

async function logOut() {
  // 1. End the Authelia session first. oauth2-proxy's sign_out (Kuma) redirects to "/", and the
  //    blind request follows that redirect into a new login; with Authelia still logged in, that
  //    login would succeed silently and leave a fresh app session behind.
  try {
    await fetch("/auth/api/logout", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
  } catch {}

  // 2. End each app's own session (apps.json "logoutUrl"). Sent "blind" (no-cors): the browser
  //    includes the app's cookie, the app ends that session, and the page doesn't need the answer.
  //    (no-cors requests must follow redirects; "manual" makes the browser drop the request.)
  const apps = await appsReady;
  await Promise.allSettled(apps.filter(a => a.logoutUrl).map(a => {
    const ctrl = new AbortController();
    setTimeout(() => ctrl.abort(), 4000);    // don't let an unreachable app block logout
    return fetch(a.logoutUrl, { method: "POST", mode: "no-cors", credentials: "include", signal: ctrl.signal });
  }));

  // 3. Reload as a guest.
  location.replace("/");
}
