/* Landing page: greeting, app tiles, login/logout button. Apps are listed in /apps.json. */

const grid = document.getElementById("apps");
const authBtn = document.getElementById("auth-btn");
let userName = "";

authReady.then(auth => {
  userName = auth.userName;
  tick();
  authBtn.textContent = auth.loggedIn ? "Log Out" : "Log In";
  authBtn.style.visibility = "visible";
  authBtn.addEventListener("click", () => {
    if (!auth.loggedIn) return logIn();
    authBtn.disabled = true;
    authBtn.textContent = "Logging out…";
    logOut();
  });
});

// Tile links depend on whether someone is logged in.
Promise.all([appsReady, authReady]).then(([apps, auth]) => {
  for (const app of apps) renderApp(app, auth.loggedIn);
});

function renderApp(app, loggedIn) {
  const card = document.createElement("a");
  card.className = "card";
  card.href = (!loggedIn && app.guestUrl) || app.url;

  const top = document.createElement("div");
  top.className = "top";
  const icon = document.createElement("span");
  icon.className = "icon"; icon.textContent = app.icon || "•";
  const name = document.createElement("span");
  name.className = "name"; name.textContent = app.name;
  const dot = document.createElement("span");
  dot.className = "dot"; dot.title = "Checking…";
  top.append(icon, name, dot);

  const desc = document.createElement("p");
  desc.className = "desc"; desc.textContent = app.description || "";
  card.append(top, desc);

  if (app.lanUrl) {
    const lan = document.createElement("a");
    lan.className = "lan"; lan.href = app.lanUrl;
    lan.textContent = "Open on home network";
    lan.addEventListener("click", e => e.stopPropagation());
    card.append(lan);
  }
  grid.append(card);
  check(app.url, dot);
}

// Rough reachability check: an opaque response means the host answered.
async function check(url, dot) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 5000);
  try {
    await fetch(url, { mode: "no-cors", cache: "no-store", signal: ctrl.signal });
    dot.classList.add("ok"); dot.title = "Reachable";
  } catch {
    dot.classList.add("down"); dot.title = "Not reachable";
  } finally { clearTimeout(t); }
}

function tick() {
  const now = new Date();
  const h = now.getHours();
  document.getElementById("greeting").textContent =
    (h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening") +
    (userName ? `, ${userName}` : "");
  document.getElementById("clock").textContent = now.toLocaleString(undefined, {
    weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit"
  });
}
tick(); setInterval(tick, 30000);
