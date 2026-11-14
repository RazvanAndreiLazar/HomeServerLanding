/* RustDesk help page: the settings for the RustDesk clients (apps/rustdesk).
   The server's key comes from /rustdesk/key, which Caddy only answers for logged-in family members. */

const $ = id => document.getElementById(id);

// One click selects the whole value, ready to copy.
for (const input of document.querySelectorAll("input[readonly]")) {
  input.addEventListener("focus", () => input.select());
}

configReady.then(cfg => {
  $("id-server").value = cfg.serverName || location.hostname;
  if (cfg.lanIp) {
    $("lan").textContent = cfg.lanIp;
    $("lan-note").hidden = false;
  }
});

authReady.then(async auth => {
  if (!auth.loggedIn) {
    $("login").hidden = false;
    $("login").addEventListener("click", () => logIn(location.href));
    return;
  }
  let key = "", status = 0;
  try {
    // "manual": a redirect to the login page (session ended meanwhile) is not followed.
    const r = await fetch("/rustdesk/key", { cache: "no-store", redirect: "manual" });
    status = r.status;
    if (r.ok) key = (await r.text()).trim();
  } catch {}
  if (key) {
    $("key").value = key;
    $("key-field").hidden = false;
  } else {
    $("key-msg").textContent = status === 403
      ? "Only family members can see the key."
      : "The key isn't available yet. Ask an admin.";
    $("key-msg").hidden = false;
  }
});
