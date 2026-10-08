/* Custom login page. Caddy serves it at /auth/ (Authelia's portal address), so it receives
   the same query parameters Authelia's own portal would: "rd" (where to go afterwards) and,
   for single sign-on requests from apps, the OIDC flow parameters.
   The browser talks to Authelia directly, so Authelia's per-IP brute-force protection applies. */

// Query parameter -> /auth/api/firstfactor body field, as Authelia 4.39's own portal sends them.
// Authelia's internal API is unversioned: re-check after upgrades (see docs/setup.md).
const FORWARDED_PARAMS = {
  rd: "targetURL",
  rm: "requestMethod",
  flow: "flow",
  flow_id: "flowID",
  subflow: "subflow",
};

const params = new URLSearchParams(location.search);
const form = document.getElementById("login");
const errorBox = document.getElementById("error");
const submit = document.getElementById("submit");

// Already logged in: go straight on.
authReady.then(auth => { if (auth.loggedIn) continueTo(); });

form.addEventListener("submit", async e => {
  e.preventDefault();
  const username = form.username.value.trim();
  const password = form.password.value;
  if (!username || !password) return showError("Enter your username and password.");

  const body = { username, password, keepMeLoggedIn: form.remember.checked };
  for (const [param, field] of Object.entries(FORWARDED_PARAMS)) {
    if (params.has(param)) body[field] = params.get(param);
  }

  submit.disabled = true;
  submit.textContent = "Logging in…";
  showError("");
  try {
    const r = await fetch("/auth/api/firstfactor", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const res = await r.json().catch(() => ({}));
    if (r.ok && res.status === "OK") return continueTo(res.data?.redirect);
    if (r.status === 429) showError("Too many attempts. Wait a few minutes and try again.");
    else if (r.status === 401 || r.status === 403) showError("Wrong username or password. After several failed attempts, logging in is blocked for a while.");
    else showError("Login failed. Try again.");
  } catch {
    showError("The login service did not answer. Try again in a moment.");
  }
  submit.disabled = false;
  submit.textContent = "Log in";
  form.password.select();
});

// Authelia's redirect wins (it has validated it). Otherwise "rd", if it points into the tailnet.
async function continueTo(redirect) {
  if (redirect) return location.replace(redirect);
  const rd = params.get("rd");
  if (rd && (await isSafeTarget(rd))) return location.replace(rd);
  location.replace("/");
}

async function isSafeTarget(url) {
  try {
    const u = new URL(url);
    if (u.origin === location.origin) return true;
    const tailnet = tailnetOf(await configReady);
    return u.protocol === "https:" && !!tailnet && u.hostname.endsWith("." + tailnet);
  } catch { return false; }
}

function showError(msg) {
  errorBox.textContent = msg;
  errorBox.hidden = !msg;
}
