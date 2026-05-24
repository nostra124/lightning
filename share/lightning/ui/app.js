// Lightning wallet PWA (FEAT-209) — a thin, same-origin client for the
// FEAT-212 account HTTP API.  No framework, no build step.
//
// Auth (this PR): the `lt_…` API key minted at account creation.  It is
// shown once on the backup screen and then kept in localStorage so the
// wallet works across launches.  Passkey/WebAuthn login (no plaintext
// bearer on the device) is the follow-up backend (FEAT-209 PR-2b).

const LS_KEY = "lightning.accounts";

let CONFIG = { api_base: "/.well-known/lightning/v1" };

async function loadConfig() {
  try {
    const r = await fetch("config.json", { cache: "no-store" });
    if (r.ok) CONFIG = { ...CONFIG, ...(await r.json()) };
  } catch (_) { /* defaults are fine */ }
}

// --- account store (localStorage) ----------------------------------------

function accounts() {
  try { return JSON.parse(localStorage.getItem(LS_KEY) || "[]"); }
  catch (_) { return []; }
}
function saveAccounts(list) { localStorage.setItem(LS_KEY, JSON.stringify(list)); }
function getAccount(id) { return accounts().find(a => a.id === id); }
function upsertAccount(acct) {
  const list = accounts().filter(a => a.id !== acct.id);
  list.push(acct); saveAccounts(list);
}
function removeAccount(id) { saveAccounts(accounts().filter(a => a.id !== id)); }

// --- API ------------------------------------------------------------------

async function api(path, { method = "GET", key, body } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (key) headers["Authorization"] = "Bearer " + key;
  const r = await fetch(CONFIG.api_base + path, {
    method, headers, body: body ? JSON.stringify(body) : undefined,
  });
  let data = null;
  try { data = await r.json(); } catch (_) { /* may be empty */ }
  if (!r.ok) {
    const msg = (data && (data.error || data.detail)) || ("HTTP " + r.status);
    throw new Error(msg);
  }
  return data;
}

// --- tiny render helpers --------------------------------------------------

const app = () => document.getElementById("app");
function h(html) { app().innerHTML = html; }
function esc(s) { return String(s ?? "").replace(/[&<>"]/g, c =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }
function go(hash) { location.hash = hash; }
function toast(msg, kind = "info") {
  const el = document.createElement("div");
  el.className = "toast " + kind;
  el.textContent = msg;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 4000);
}

function renderNav() {
  const nav = document.getElementById("nav");
  const list = accounts();
  nav.innerHTML = list.length
    ? '<a href="#picker">Accounts</a>'
    : "";
}

// --- screens --------------------------------------------------------------

function screenPicker() {
  const list = accounts();
  if (list.length === 0) return screenWelcome();
  h(`<h2>Your accounts</h2>
     <ul class="cards">${list.map(a => `
       <li><a href="#account/${esc(a.id)}">
         <strong>${esc(a.label || "account")}</strong>
         <code>${esc(a.id.slice(0, 14))}…</code></a></li>`).join("")}
     </ul>
     <button id="add">+ New account</button>`);
  document.getElementById("add").onclick = () => go("create");
}

function screenWelcome() {
  h(`<h2>Welcome</h2>
     <p>A self-custodial-by-default Lightning wallet. Create your first
        account to get a top-up address and start paying / receiving.</p>
     <button id="create">Create my first account</button>`);
  document.getElementById("create").onclick = () => go("create");
}

async function screenCreate() {
  h(`<h2>Create account</h2>
     <label>Label (this device only)
       <input id="label" placeholder="e.g. pocket money" maxlength="40"></label>
     <button id="go">Create</button>
     <p class="muted">Creates an anonymous account on this node and mints
        an API key. You'll save the key on the next screen.</p>`);
  document.getElementById("go").onclick = async () => {
    document.getElementById("go").disabled = true;
    try {
      const label = document.getElementById("label").value.trim();
      const res = await api("/accounts", { method: "POST", body: label ? { hint: label } : {} });
      const acct = { id: res.account_id, label: label || "account", key: res.api_key };
      upsertAccount(acct);
      screenBackup(acct, res);
    } catch (e) {
      toast("Create failed: " + e.message, "error");
      document.getElementById("go").disabled = false;
    }
  };
}

function screenBackup(acct, res) {
  h(`<h2>Save your API key</h2>
     <p class="warn">This is shown <strong>once</strong>. It is your backup
        credential — store it somewhere safe. Anyone with it controls this
        account.</p>
     <pre id="key" class="key">${esc(acct.key)}</pre>
     <button id="copy">Copy</button>
     <button id="dl">Download</button>
     <button id="done" class="primary">I've saved it — continue</button>`);
  document.getElementById("copy").onclick = async () => {
    try { await navigator.clipboard.writeText(acct.key); toast("Copied"); }
    catch (_) { toast("Copy failed — select + copy manually", "error"); }
  };
  document.getElementById("dl").onclick = () => {
    const blob = new Blob(
      [`lightning account ${acct.id}\napi_key ${acct.key}\n`], { type: "text/plain" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `lightning-${acct.id.slice(0, 10)}.key.txt`;
    a.click();
  };
  document.getElementById("done").onclick = () => go("account/" + acct.id);
}

async function screenAccount(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  h(`<h2>${esc(acct.label)}</h2><p class="muted"><code>${esc(id)}</code></p>
     <p id="bal" class="balance">…</p>
     <div class="row">
       <button id="send">Send</button>
       <button id="recv">Receive</button>
       <button id="topup">Top up</button>
       <button id="settings">⚙</button>
     </div>
     <div id="topupbox"></div>`);
  document.getElementById("send").onclick = () => go("send/" + id);
  document.getElementById("recv").onclick = () => go("recv/" + id);
  document.getElementById("settings").onclick = () => go("settings/" + id);
  document.getElementById("topup").onclick = () => showTopup(id, acct.key);
  try {
    const b = await api(`/accounts/${id}/balance`, { key: acct.key });
    document.getElementById("bal").textContent = (b.balance_sat ?? 0).toLocaleString() + " sat";
  } catch (e) {
    document.getElementById("bal").textContent = "—";
    toast("Balance: " + e.message, "error");
  }
}

async function showTopup(id, key) {
  const box = document.getElementById("topupbox");
  box.innerHTML = '<p class="muted">Fetching top-up address…</p>';
  try {
    const t = await api(`/accounts/${id}/topup`, { key });
    box.innerHTML = `<div class="card">
      <p>Send on-chain BTC to this address; the node credits your ledger
         within ~1 minute.</p>
      <pre class="key">${esc(t.address || "")}</pre>
      <p class="muted">${esc(t.uri || "")}</p></div>`;
  } catch (e) { box.innerHTML = `<p class="error">${esc(e.message)}</p>`; }
}

function screenSend(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  h(`<h2>Send</h2>
     <label>BOLT-11 invoice
       <textarea id="bolt11" rows="3" placeholder="lnbc…"></textarea></label>
     <button id="pay" class="primary">Pay</button>
     <a href="#account/${esc(id)}">Cancel</a>`);
  document.getElementById("pay").onclick = async () => {
    const target = document.getElementById("bolt11").value.trim();
    if (!target) return toast("Paste an invoice", "error");
    document.getElementById("pay").disabled = true;
    try {
      const r = await api(`/accounts/${id}/pay`, { method: "POST", key: acct.key, body: { target } });
      toast("Paid — " + (r.amount_sat ?? "?") + " sat", "ok");
      go("account/" + id);
    } catch (e) {
      toast("Pay failed: " + e.message, "error");
      document.getElementById("pay").disabled = false;
    }
  };
}

function screenRecv(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  h(`<h2>Receive</h2>
     <label>Amount (sat)<input id="sat" type="number" min="1" placeholder="1000"></label>
     <label>Description<input id="desc" maxlength="128" placeholder="optional"></label>
     <button id="mint" class="primary">Create invoice</button>
     <div id="inv"></div>
     <a href="#account/${esc(id)}">Back</a>`);
  document.getElementById("mint").onclick = async () => {
    const sat = parseInt(document.getElementById("sat").value, 10);
    const description = document.getElementById("desc").value.trim();
    if (!Number.isInteger(sat) || sat <= 0) return toast("Enter a positive amount", "error");
    try {
      const r = await api(`/accounts/${id}/recv`, { method: "POST", key: acct.key, body: { sat, description } });
      document.getElementById("inv").innerHTML =
        `<div class="card"><p>Share this invoice:</p>
         <pre class="key">${esc(r.bolt11 || "")}</pre></div>`;
    } catch (e) { toast("Mint failed: " + e.message, "error"); }
  };
}

function screenSettings(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  h(`<h2>Settings — ${esc(acct.label)}</h2>
     <button id="showkey">Show API key (for LLM agents / CLI)</button>
     <pre id="key" class="key" hidden>${esc(acct.key)}</pre>
     <button id="remove" class="danger">Remove from this device</button>
     <p class="muted">Removing only forgets the account locally; the account
        and its funds stay on the node. Re-add it with its API key.</p>
     <a href="#account/${esc(id)}">Back</a>`);
  document.getElementById("showkey").onclick = () =>
    document.getElementById("key").hidden = !document.getElementById("key").hidden;
  document.getElementById("remove").onclick = () => {
    if (confirm("Forget this account on this device?")) { removeAccount(id); go("picker"); }
  };
}

// --- router ---------------------------------------------------------------

function route() {
  renderNav();
  const hash = location.hash.replace(/^#/, "");
  const [screen, arg] = hash.split("/");
  switch (screen) {
    case "": case "picker": return screenPicker();
    case "create": return screenCreate();
    case "account": return screenAccount(arg);
    case "send": return screenSend(arg);
    case "recv": return screenRecv(arg);
    case "settings": return screenSettings(arg);
    default: return screenPicker();
  }
}

window.addEventListener("hashchange", route);

(async function main() {
  await loadConfig();
  document.getElementById("apibase").textContent = "API: " + CONFIG.api_base;
  route();
})();
