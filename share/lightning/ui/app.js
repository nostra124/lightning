// Lightning wallet PWA (FEAT-209 + FEAT-222 PR-7) — a thin, same-origin
// client for the FEAT-212 account HTTP API and the FEAT-222 user layer.
//
// Auth: account-level `lt_…` bearer for API calls; user-level passkey /
// session token (sess_…) for the user-registration and login flows.

const LS_KEY = "lightning.accounts";
// User store: {user_id, label} persisted; session kept only in sessionStorage.
const LS_USER_KEY = "lightning.user";

let CONFIG = { api_base: "/.well-known/lightning/v1" };

async function loadConfig() {
  try {
    const r = await fetch("config.json", { cache: "no-store" });
    if (r.ok) CONFIG = { ...CONFIG, ...(await r.json()) };
  } catch (_) { /* defaults are fine */ }
}

// FEAT-220 — honour ?invite=<code> from the moment the PWA loads: stash
// it for the create flow, then drop it from the address bar so it
// doesn't linger across navigation.
function consumeInviteParam() {
  const code = new URLSearchParams(location.search).get("invite");
  if (code) {
    sessionStorage.setItem("lightning.invite", code);
    history.replaceState(null, "", location.pathname + location.hash);
  }
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

// --- user store (FEAT-222 PR-7) ------------------------------------------

function storedUser() {
  try { return JSON.parse(localStorage.getItem(LS_USER_KEY) || "null"); }
  catch (_) { return null; }
}
function saveUser(u) {
  if (u) localStorage.setItem(LS_USER_KEY, JSON.stringify(u));
  else localStorage.removeItem(LS_USER_KEY);
}
function userSession() { return sessionStorage.getItem("lightning.session"); }
function saveSession(s) { sessionStorage.setItem("lightning.session", s); }
function clearSession() { sessionStorage.removeItem("lightning.session"); }

// --- WebAuthn helpers (FEAT-222 PR-7) ------------------------------------

function b64url(buf) {
  return btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}
function b64urlDecode(s) {
  const p = s.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(p + "=".repeat((4 - p.length % 4) % 4)), c => c.charCodeAt(0));
}

// Build a credential create response JSON (attestation) for the server.
async function passkeyCreate(options) {
  const opts = {
    publicKey: {
      ...options,
      challenge: b64urlDecode(options.challenge),
      user: { ...options.user, id: b64urlDecode(options.user.id) },
      rp: options.rp,
    },
  };
  const cred = await navigator.credentials.create(opts);
  return {
    id: cred.id,
    rawId: b64url(cred.rawId),
    type: cred.type,
    response: {
      attestationObject: b64url(cred.response.attestationObject),
      clientDataJSON:    b64url(cred.response.clientDataJSON),
    },
  };
}

// Build a credential get response JSON (assertion) for the server.
async function passkeyGet(options) {
  const allowCreds = (options.allowCredentials || []).map(c => ({
    ...c, id: b64urlDecode(c.id),
  }));
  const opts = {
    publicKey: {
      ...options,
      challenge: b64urlDecode(options.challenge),
      allowCredentials: allowCreds,
    },
  };
  const cred = await navigator.credentials.get(opts);
  return {
    id: cred.id,
    rawId: b64url(cred.rawId),
    type: cred.type,
    response: {
      authenticatorData: b64url(cred.response.authenticatorData),
      clientDataJSON:    b64url(cred.response.clientDataJSON),
      signature:         b64url(cred.response.signature),
      userHandle: cred.response.userHandle ? b64url(cred.response.userHandle) : null,
    },
  };
}

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

// --- user registration / login screens (FEAT-222 PR-7) ------------------

async function screenUserRegister() {
  h(`<h2>Create user account</h2>
     <p class="muted">Register with a passkey to manage multiple accounts
        under one identity. An invite code is required if the operator has
        enabled invite-only mode.</p>
     <label>Invite code (if required)
       <input id="invite" placeholder="optional" maxlength="32"></label>
     <label>Your name / label
       <input id="label" placeholder="e.g. Alice" maxlength="64"></label>
     <button id="go" class="primary">Register with passkey</button>
     <p class="muted"><a href="#user-login">Already registered? Log in</a></p>`);
  const invite = sessionStorage.getItem("lightning.invite");
  if (invite) document.getElementById("invite").value = invite;
  document.getElementById("go").onclick = async () => {
    document.getElementById("go").disabled = true;
    const invite_code = document.getElementById("invite").value.trim();
    const label       = document.getElementById("label").value.trim();
    try {
      // Step 1: get a challenge + provisional user_id.
      const beginData = await api("/users/register/begin", { method: "POST" });
      const { user_id, ...createOptions } = beginData;
      // Step 2: browser creates the passkey.
      const attestation = await passkeyCreate(createOptions);
      // Step 3: finish registration — creates user + registers passkey.
      const body = { user_id, passkey_attestation: { challenge: createOptions.challenge, attestation }, label };
      if (invite_code) body.invite_code = invite_code;
      const res = await api("/users", { method: "POST", body });
      saveUser({ user_id: res.user_id, label: label || "user" });
      saveSession(res.session);
      sessionStorage.removeItem("lightning.invite");
      toast("Registered! Loading your accounts…", "ok");
      go("user");
    } catch (e) {
      toast("Registration failed: " + e.message, "error");
      document.getElementById("go").disabled = false;
    }
  };
}

async function screenUserLogin() {
  const stored = storedUser();
  h(`<h2>Log in with passkey</h2>
     ${stored ? `<p>Logging in as <strong>${esc(stored.label || stored.user_id)}</strong>.</p>` : ""}
     <button id="go" class="primary">Authenticate</button>
     <p class="muted"><a href="#user-register">New here? Register</a></p>
     <p class="muted"><a href="#picker">Continue without user account</a></p>`);
  if (!stored) { toast("No user registered on this device", "error"); return; }
  document.getElementById("go").onclick = async () => {
    document.getElementById("go").disabled = true;
    const { user_id } = stored;
    try {
      const beginData = await api(`/users/${user_id}/passkeys/login/begin`, { method: "POST" });
      const assertion = await passkeyGet(beginData);
      const res = await api(`/users/${user_id}/passkeys/login/finish`, {
        method: "POST",
        body:   { challenge: beginData.challenge, assertion },
      });
      saveSession(res.session);
      toast("Logged in", "ok");
      go("user");
    } catch (e) {
      toast("Login failed: " + e.message, "error");
      document.getElementById("go").disabled = false;
    }
  };
}

async function screenUser() {
  const user = storedUser();
  const session = userSession();
  if (!user || !session) return go("user-login");
  h(`<h2>${esc(user.label || "Your accounts")}</h2>
     <div id="list"><p class="muted">Loading…</p></div>
     <button id="newacct">+ New account</button>
     <button id="logout" class="danger">Log out</button>`);
  const apiUser = (path, opts = {}) =>
    api(path, { ...opts, key: session });
  document.getElementById("newacct").onclick = async () => {
    try {
      const res = await apiUser(`/users/${user.user_id}/accounts`, {
        method: "POST", body: {},
      });
      upsertAccount({ id: res.account_id, label: "account", key: res.api_key });
      toast("Account created", "ok");
      screenUser();
    } catch (e) { toast("Failed: " + e.message, "error"); }
  };
  document.getElementById("logout").onclick = () => {
    clearSession(); toast("Logged out", "ok"); go("picker");
  };
  try {
    const r = await apiUser(`/users/${user.user_id}/accounts`);
    const list = r.accounts || [];
    document.getElementById("list").innerHTML = list.length
      ? `<ul class="cards">${list.map(a => {
          const local = getAccount(a.account_id);
          return `<li><a href="#account/${esc(a.account_id)}">
            <strong>${esc(local ? local.label : "account")}</strong>
            <code>${esc((a.account_id || "").slice(0, 14))}…</code>
          </a>
          ${!local ? `<button class="small" data-id="${esc(a.account_id)}">Load API key</button>` : ""}</li>`;
        }).join("")}</ul>`
      : '<p class="muted">No accounts yet. Create one above.</p>';
    document.querySelectorAll("button[data-id]").forEach(b => b.onclick = async () => {
      const aid = b.getAttribute("data-id");
      try {
        const kr = await apiUser(`/users/${user.user_id}/accounts/${aid}/api-key`);
        upsertAccount({ id: aid, label: "account", key: kr.api_key });
        toast("Account loaded", "ok"); screenUser();
      } catch (e) { toast("Failed: " + e.message, "error"); }
    });
  } catch (e) {
    document.getElementById("list").innerHTML = `<p class="error">${esc(e.message)}</p>`;
    if (e.message.includes("401") || e.message.includes("session")) {
      clearSession(); go("user-login");
    }
  }
}

function screenPicker() {
  const list = accounts();
  const user = storedUser();
  if (list.length === 0 && !user) return screenWelcome();
  const userLink = user
    ? `<p class="muted"><a href="#user">Switch to user view (${esc(user.label || user.user_id)})</a></p>`
    : `<p class="muted"><a href="#user-register">Register / log in as user (multi-account)</a></p>`;
  h(`<h2>Your accounts</h2>
     <ul class="cards">${list.map(a => `
       <li><a href="#account/${esc(a.id)}">
         <strong>${esc(a.label || "account")}</strong>
         <code>${esc(a.id.slice(0, 14))}…</code></a></li>`).join("")}
     </ul>
     <button id="add">+ New account</button>
     ${userLink}`);
  document.getElementById("add").onclick = () => go("create");
}

function screenWelcome() {
  h(`<h2>Welcome</h2>
     <p>A self-custodial-by-default Lightning wallet. Create your first
        account to get a top-up address and start paying / receiving.</p>
     <button id="create">Create my first account</button>
     <p class="muted">Have an invite code?
       <a href="#user-register">Register as a user</a> to manage multiple
       accounts under one passkey.</p>`);
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
      const body = {};
      if (label) body.hint = label;
      const invite = sessionStorage.getItem("lightning.invite");
      if (invite) body.invite_code = invite;
      const res = await api("/accounts", { method: "POST", body });
      sessionStorage.removeItem("lightning.invite");
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

// FEAT-231 — fiat display.  Fetch the public price tick once and cache
// the fiat-per-sat rate for the session.
let FIAT = null;  // { base, per_sat } or null if unavailable
async function fiatPerSat() {
  if (FIAT !== null) return FIAT;
  const base = CONFIG.base_fiat || "EUR";
  try {
    const r = await fetch(CONFIG.api_base + "/price?base=" + encodeURIComponent(base));
    const d = await r.json();
    if (d && d.btc_fiat) { FIAT = { base, per_sat: d.btc_fiat / 1e8 }; return FIAT; }
  } catch (_) { /* price feed optional */ }
  FIAT = { base, per_sat: 0 };
  return FIAT;
}
async function fiatTag(sat) {
  const f = await fiatPerSat();
  if (!f.per_sat) return "";
  return " ≈ " + (sat * f.per_sat).toFixed(2) + " " + f.base;
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
       <button id="history">History</button>
       <button id="commerce">Commerce</button>
       <button id="settings">⚙</button>
     </div>
     <div id="topupbox"></div>`);
  document.getElementById("send").onclick = () => go("send/" + id);
  document.getElementById("recv").onclick = () => go("recv/" + id);
  document.getElementById("history").onclick = () => go("history/" + id);
  document.getElementById("settings").onclick = () => go("settings/" + id);
  document.getElementById("commerce").onclick = () => go("commerce/" + id);
  document.getElementById("topup").onclick = () => showTopup(id, acct.key);
  try {
    const b = await api(`/accounts/${id}/balance`, { key: acct.key });
    const sat = b.balance_sat ?? 0;
    document.getElementById("bal").textContent = sat.toLocaleString() + " sat" + (await fiatTag(sat));
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

// FEAT-248 — improved Send UX: universal target label, fee in receipt.
function screenSend(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  h(`<h2>Send</h2>
     <label>Invoice / Lightning address / offer
       <textarea id="bolt11" rows="3" placeholder="lnbc… · lno… · user@domain.com"></textarea></label>
     <button id="pay" class="primary">Pay</button>
     <a href="#account/${esc(id)}">Cancel</a>`);
  document.getElementById("pay").onclick = async () => {
    const target = document.getElementById("bolt11").value.trim();
    if (!target) return toast("Paste an invoice, Lightning address, or offer", "error");
    document.getElementById("pay").disabled = true;
    try {
      const r = await api(`/accounts/${id}/pay`, { method: "POST", key: acct.key, body: { target } });
      const fee = r.fee_sat != null ? " (fee: " + r.fee_sat + " sat)" : "";
      toast("Paid — " + (r.amount_sat ?? "?") + " sat" + fee, "ok");
      go("account/" + id);
    } catch (e) {
      toast("Pay failed: " + e.message, "error");
      document.getElementById("pay").disabled = false;
    }
  };
}

// FEAT-245 — BOLT-11 invoice + BOLT-12 reusable offer on the same screen.
function screenRecv(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  h(`<h2>Receive</h2>
     <div class="row" id="recv-tabs">
       <button id="tab-bolt11" class="primary">Invoice (BOLT-11)</button>
       <button id="tab-bolt12">Reusable offer (BOLT-12)</button>
     </div>
     <div id="recv-bolt11">
       <label>Amount (sat)<input id="sat" type="number" min="1" placeholder="1000"></label>
       <label>Description<input id="desc" maxlength="128" placeholder="optional"></label>
       <button id="mint" class="primary">Create invoice</button>
     </div>
     <div id="recv-bolt12" style="display:none">
       <label>Amount (sat, or leave blank for any amount)<input id="sat12" type="number" min="1" placeholder="any"></label>
       <label>Description<input id="desc12" maxlength="128" placeholder="optional"></label>
       <button id="mint12" class="primary">Get reusable offer</button>
     </div>
     <div id="inv"></div>
     <a href="#account/${esc(id)}">Back</a>`);

  document.getElementById("tab-bolt11").onclick = () => {
    document.getElementById("recv-bolt11").style.display = "";
    document.getElementById("recv-bolt12").style.display = "none";
    document.getElementById("tab-bolt11").classList.add("primary");
    document.getElementById("tab-bolt12").classList.remove("primary");
    document.getElementById("inv").innerHTML = "";
  };
  document.getElementById("tab-bolt12").onclick = () => {
    document.getElementById("recv-bolt11").style.display = "none";
    document.getElementById("recv-bolt12").style.display = "";
    document.getElementById("tab-bolt12").classList.add("primary");
    document.getElementById("tab-bolt11").classList.remove("primary");
    document.getElementById("inv").innerHTML = "";
  };

  document.getElementById("mint").onclick = async () => {
    const sat = parseInt(document.getElementById("sat").value, 10);
    const description = document.getElementById("desc").value.trim();
    if (!Number.isInteger(sat) || sat <= 0) return toast("Enter a positive amount", "error");
    try {
      const r = await api(`/accounts/${id}/recv`, { method: "POST", key: acct.key, body: { sat, description } });
      const inv = r.bolt11 || "";
      document.getElementById("inv").innerHTML =
        `<div class="card"><p>Share this invoice:</p>
         <pre class="key">${esc(inv)}</pre>
         <button id="copy-inv">Copy</button></div>`;
      document.getElementById("copy-inv").onclick = () =>
        navigator.clipboard.writeText(inv).then(() => toast("Copied", "ok"))
          .catch(() => toast("Copy failed", "error"));
    } catch (e) { toast("Mint failed: " + e.message, "error"); }
  };

  document.getElementById("mint12").onclick = async () => {
    const satVal = document.getElementById("sat12").value.trim();
    const description = document.getElementById("desc12").value.trim();
    const sat = satVal === "" ? "any" : parseInt(satVal, 10);
    if (sat !== "any" && (!Number.isInteger(sat) || sat <= 0))
      return toast("Enter a positive amount or leave blank for any", "error");
    try {
      const r = await api(`/accounts/${id}/recv-reusable`, { method: "POST", key: acct.key, body: { sat, description } });
      const offer = r.bolt12 || "";
      document.getElementById("inv").innerHTML =
        `<div class="card"><p>Reusable BOLT-12 offer (share freely — payers can pay multiple times):</p>
         <pre class="key">${esc(offer)}</pre>
         <button id="copy-offer">Copy</button></div>`;
      document.getElementById("copy-offer").onclick = () =>
        navigator.clipboard.writeText(offer).then(() => toast("Copied", "ok"))
          .catch(() => toast("Copy failed", "error"));
    } catch (e) { toast("Offer failed: " + e.message, "error"); }
  };
}

// FEAT-220 — invite a friend + my referrals.
async function screenReferrals(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  h(`<h2>Invite &amp; referrals</h2>
     <h3>Invite a friend</h3>
     <div id="invite" class="card"><p class="muted">Loading…</p></div>
     <h3>My referrals</h3>
     <div id="refs" class="card"><p class="muted">Loading…</p></div>
     <a href="#settings/${esc(id)}">Back</a>`);

  try {
    const r = await api(`/accounts/${id}/invite-codes`, { key: acct.key });
    const code = (r.invite_codes && r.invite_codes[0] && r.invite_codes[0].code) || "";
    const base = location.origin + location.pathname.replace(/index\.html$/, "");
    const link = base + "?invite=" + encodeURIComponent(code);
    const box = document.getElementById("invite");
    if (!code) { box.innerHTML = '<p class="muted">No invite code available.</p>'; }
    else {
      box.innerHTML = `<p>Your code: <strong>${esc(code)}</strong></p>
        <p class="muted">Share this link — anyone who creates an account from
           it is referred to you, and you earn a slice of their fees.</p>
        <pre class="key">${esc(link)}</pre>
        <button id="copy">Copy link</button>
        <button id="share" hidden>Share…</button>`;
      document.getElementById("copy").onclick = async () => {
        try { await navigator.clipboard.writeText(link); toast("Copied"); }
        catch (_) { toast("Copy failed — select + copy manually", "error"); }
      };
      const sh = document.getElementById("share");
      if (navigator.share) {
        sh.hidden = false;
        sh.onclick = () => navigator.share({ url: link, title: "Join me on Lightning" }).catch(() => {});
      }
    }
  } catch (e) {
    document.getElementById("invite").innerHTML = `<p class="error">${esc(e.message)}</p>`;
  }

  try {
    const r = await api(`/accounts/${id}/referrals`, { key: acct.key });
    const list = r.referrals || [];
    document.getElementById("refs").innerHTML = list.length
      ? `<ul class="cards">${list.map(x => `<li>
          <code>${esc(String(x.account_id || "").slice(0, 8))}…</code>
          <span class="muted">joined ${esc(new Date((x.joined_at || 0) * 1000).toISOString().slice(0, 10))}
          · ${esc((x.accrued_credits_sat ?? 0).toLocaleString())} sat</span></li>`).join("")}</ul>`
      : '<p class="muted">No referrals yet — share your link above.</p>';
  } catch (e) {
    document.getElementById("refs").innerHTML = `<p class="error">${esc(e.message)}</p>`;
  }
}

function screenSettings(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  const year = new Date().getUTCFullYear();
  h(`<h2>Settings — ${esc(acct.label)}</h2>
     <button id="referrals">Invite &amp; referrals</button>
     <button id="taxdata">Export transaction data (for tax)</button>
     <p class="muted">${year} — source data for tax preparation, not a report.</p>
     <button id="showkey">Show API key (for LLM agents / CLI)</button>
     <pre id="key" class="key" hidden>${esc(acct.key)}</pre>
     <button id="dlbackup">Download backup</button>
     <p class="muted">Saves account_id + API key as a JSON file for recovery.</p>
     <button id="remove" class="danger">Remove from this device</button>
     <p class="muted">Removing only forgets the account locally; the account
        and its funds stay on the node. Re-add it with its API key.</p>
     <a href="#account/${esc(id)}">Back</a>`);
  document.getElementById("referrals").onclick = () => go("referrals/" + id);
  document.getElementById("taxdata").onclick = async () => {
    // Bearer-authed download → fetch + blob (a plain link can't set the header).
    try {
      const base = CONFIG.base_fiat || "EUR";
      const r = await fetch(`${CONFIG.api_base}/accounts/${id}/export/tax-data?year=${year}&base=${base}&format=csv`,
        { headers: { "Authorization": "Bearer " + acct.key } });
      if (!r.ok) throw new Error("HTTP " + r.status);
      const blob = await r.blob();
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = `lightning-tax-data-${year}.csv`;
      a.click();
    } catch (e) { toast("Export failed: " + e.message, "error"); }
  };
  document.getElementById("showkey").onclick = () =>
    document.getElementById("key").hidden = !document.getElementById("key").hidden;
  document.getElementById("dlbackup").onclick = () => {
    const blob = new Blob(
      [JSON.stringify({ account_id: id, api_key: acct.key }, null, 2)],
      { type: "application/json" }
    );
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `lightning-backup-${id.slice(0, 12)}.json`;
    a.click();
  };
  document.getElementById("remove").onclick = () => {
    if (confirm("Forget this account on this device?")) { removeAccount(id); go("picker"); }
  };
}

// --- router ---------------------------------------------------------------

// --- FEAT-231 commerce + POS ----------------------------------------------

let POLL = null;  // POS settle poller; cleared on navigation.

function screenCommerce(id) {
  if (!getAccount(id)) return go("picker");
  h(`<h2>Commerce</h2>
     <div class="cards">
       <button id="pos">🧾 Point of sale</button>
       <button id="transfer">↗ Transfer to an account</button>
       <button id="so">🔁 Standing orders</button>
       <button id="mandates">📥 Direct-debit mandates</button>
     </div>
     <a href="#account/${esc(id)}">Back</a>`);
  document.getElementById("pos").onclick = () => go("pos/" + id);
  document.getElementById("transfer").onclick = () => go("transfer/" + id);
  document.getElementById("so").onclick = () => go("so/" + id);
  document.getElementById("mandates").onclick = () => go("mandates/" + id);
}

async function screenPOS(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  h(`<h2>Point of sale</h2>
     <label>Amount (sat)<input id="sat" type="number" min="1" placeholder="1000"></label>
     <p class="muted" id="fiat"></p>
     <label>Order reference (optional)<input id="ref" maxlength="64" placeholder="order #"></label>
     <button id="charge" class="primary">Charge</button>
     <div id="out"></div>
     <a href="#commerce/${esc(id)}">Back</a>`);
  const satEl = document.getElementById("sat");
  satEl.oninput = async () => {
    const s = parseInt(satEl.value, 10);
    document.getElementById("fiat").textContent =
      Number.isInteger(s) && s > 0 ? (await fiatTag(s)).replace(/^ ≈ /, "≈ ") : "";
  };
  document.getElementById("charge").onclick = async () => {
    const sat = parseInt(satEl.value, 10);
    if (!Number.isInteger(sat) || sat <= 0) return toast("Enter a positive amount", "error");
    const ref = document.getElementById("ref").value.trim();
    const body = { sat };
    if (ref) body.reference = { order_id: ref };
    try {
      const inv = await api(`/accounts/${id}/invoice`, { method: "POST", key: acct.key, body });
      const out = document.getElementById("out");
      out.innerHTML = `<div class="card">
        <p>Show this invoice to the payer:</p>
        <pre class="key">${esc(inv.bolt11 || "")}</pre>
        <p id="status" class="warn">Waiting for payment…</p></div>`;
      // Poll the invoice lookup until paid.
      const hash = inv.payment_hash;
      if (POLL) clearInterval(POLL);
      POLL = setInterval(async () => {
        try {
          const st = await api(`/accounts/${id}/invoice/${hash}`, { key: acct.key });
          if (st.paid) {
            clearInterval(POLL); POLL = null;
            document.getElementById("status").className = "ok";
            document.getElementById("status").textContent =
              "✓ PAID — " + (st.effective_sat ?? sat).toLocaleString() + " sat";
          }
        } catch (_) { /* keep polling */ }
      }, 3000);
    } catch (e) { toast("Charge failed: " + e.message, "error"); }
  };
}

async function screenTransfer(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  h(`<h2>Transfer</h2>
     <label>To (account name or address)<input id="to" placeholder="bcrt1… or name"></label>
     <label>Amount (sat)<input id="sat" type="number" min="1"></label>
     <label>Note<input id="note" maxlength="128" placeholder="optional"></label>
     <button id="go" class="primary">Send</button>
     <a href="#commerce/${esc(id)}">Back</a>`);
  document.getElementById("go").onclick = async () => {
    const to = document.getElementById("to").value.trim();
    const sat = parseInt(document.getElementById("sat").value, 10);
    const note = document.getElementById("note").value.trim();
    if (!to) return toast("Enter a recipient", "error");
    if (!Number.isInteger(sat) || sat <= 0) return toast("Enter a positive amount", "error");
    const body = { to, sat };
    if (note) body.note = note;
    try {
      await api(`/accounts/${id}/transfer`, { method: "POST", key: acct.key, body });
      toast("Transferred " + sat + " sat", "ok");
      go("account/" + id);
    } catch (e) { toast("Transfer failed: " + e.message, "error"); }
  };
}

async function screenStandingOrders(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  h(`<h2>Standing orders</h2>
     <div id="list"><p class="muted">Loading…</p></div>
     <h3>New</h3>
     <label>Target (account / LN address / offer)<input id="target"></label>
     <label>Amount (sat)<input id="sat" type="number" min="1"></label>
     <label>Cadence<select id="cadence">
       <option value="daily">daily</option><option value="weekly">weekly</option>
       <option value="monthly" selected>monthly</option></select></label>
     <button id="create" class="primary">Create</button>
     <a href="#commerce/${esc(id)}">Back</a>`);
  const refresh = async () => {
    try {
      const r = await api(`/accounts/${id}/standing-orders`, { key: acct.key });
      const list = r.standing_orders || [];
      document.getElementById("list").innerHTML = list.length
        ? `<ul class="cards">${list.map(o => `<li>
            <span><strong>${esc(o.target)}</strong> ${esc((o.sat ?? 0).toLocaleString())} sat / ${esc(o.cadence)}
            <span class="muted">(${esc(o.status)})</span></span>
            <span>
              ${o.status === "active" ? `<button data-act="pause" data-id="${esc(o.id)}">Pause</button>`
                : `<button data-act="resume" data-id="${esc(o.id)}">Resume</button>`}
              <button class="danger" data-act="cancel" data-id="${esc(o.id)}">Cancel</button>
            </span></li>`).join("")}</ul>`
        : '<p class="muted">No standing orders.</p>';
      document.querySelectorAll("#list button[data-act]").forEach(b => b.onclick = async () => {
        const soid = b.getAttribute("data-id"), act = b.getAttribute("data-act");
        try {
          if (act === "cancel") await api(`/accounts/${id}/standing-orders/${soid}`, { method: "DELETE", key: acct.key });
          else await api(`/accounts/${id}/standing-orders/${soid}`, { method: "POST", key: acct.key, body: { action: act } });
          refresh();
        } catch (e) { toast(e.message, "error"); }
      });
    } catch (e) { document.getElementById("list").innerHTML = `<p class="error">${esc(e.message)}</p>`; }
  };
  document.getElementById("create").onclick = async () => {
    const target = document.getElementById("target").value.trim();
    const sat = parseInt(document.getElementById("sat").value, 10);
    const cadence = document.getElementById("cadence").value;
    if (!target) return toast("Enter a target", "error");
    if (!Number.isInteger(sat) || sat <= 0) return toast("Enter a positive amount", "error");
    try {
      await api(`/accounts/${id}/standing-orders`, { method: "POST", key: acct.key, body: { target, sat, cadence } });
      toast("Created", "ok"); refresh();
    } catch (e) { toast("Create failed: " + e.message, "error"); }
  };
  refresh();
}

async function screenMandates(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  h(`<h2>Direct-debit mandates</h2>
     <div id="list"><p class="muted">Loading…</p></div>
     <h3>Authorize a merchant</h3>
     <label>Merchant (account / LN address)<input id="merchant"></label>
     <label>Max per period (sat)<input id="max" type="number" min="1"></label>
     <label>Period<select id="period">
       <option value="daily">daily</option><option value="weekly">weekly</option>
       <option value="monthly" selected>monthly</option></select></label>
     <label>Mode<select id="mode">
       <option value="auto">auto (pulls execute immediately)</option>
       <option value="approval">approval (I approve each pull)</option></select></label>
     <button id="create" class="primary">Authorize</button>
     <a href="#commerce/${esc(id)}">Back</a>`);
  const refresh = async () => {
    try {
      const r = await api(`/accounts/${id}/mandates`, { key: acct.key });
      const list = r.mandates || [];
      const rows = await Promise.all(list.map(async m => {
        // Best-effort: pending pulls only exist for mandates we're the
        // customer of; the endpoint is customer-scoped.
        let pulls = [];
        try { pulls = (await api(`/accounts/${id}/mandates/${m.id}/pulls`, { key: acct.key })).pulls || []; }
        catch (_) { /* not our customer mandate, or none */ }
        const pullHtml = pulls.map(p => `<div class="card">
          Pending charge: <strong>${esc((p.sat ?? 0).toLocaleString())} sat</strong>
          <button data-act="approve" data-m="${esc(m.id)}" data-p="${esc(p.pull_id)}">Approve</button>
          <button class="danger" data-act="deny" data-m="${esc(m.id)}" data-p="${esc(p.pull_id)}">Deny</button>
        </div>`).join("");
        return `<li><span><strong>${esc(m.merchant)}</strong>
          ${esc((m.max_per_period ?? 0).toLocaleString())} sat / ${esc(m.period)}
          <span class="muted">(${esc(m.mode)}, ${esc(m.status)})</span></span>
          <span>
            ${m.status !== "revoked" ? `<button class="danger" data-act="revoke" data-m="${esc(m.id)}">Revoke</button>` : ""}
          </span>${pullHtml}</li>`;
      }));
      document.getElementById("list").innerHTML = list.length
        ? `<ul class="cards">${rows.join("")}</ul>` : '<p class="muted">No mandates.</p>';
      document.querySelectorAll("#list button[data-act]").forEach(b => b.onclick = async () => {
        const act = b.getAttribute("data-act"), mid = b.getAttribute("data-m"), pid = b.getAttribute("data-p");
        try {
          if (act === "revoke") await api(`/accounts/${id}/mandates/${mid}`, { method: "DELETE", key: acct.key });
          else await api(`/accounts/${id}/mandates/${mid}/pulls/${pid}/${act}`, { method: "POST", key: acct.key });
          toast(act + "d", "ok"); refresh();
        } catch (e) { toast(e.message, "error"); }
      });
    } catch (e) { document.getElementById("list").innerHTML = `<p class="error">${esc(e.message)}</p>`; }
  };
  document.getElementById("create").onclick = async () => {
    const merchant = document.getElementById("merchant").value.trim();
    const max_per_period = parseInt(document.getElementById("max").value, 10);
    const period = document.getElementById("period").value;
    const mode = document.getElementById("mode").value;
    if (!merchant) return toast("Enter a merchant", "error");
    if (!Number.isInteger(max_per_period) || max_per_period <= 0) return toast("Enter a positive cap", "error");
    try {
      const m = await api(`/accounts/${id}/mandates`, { method: "POST", key: acct.key, body: { merchant, max_per_period, period, mode } });
      toast("Authorized — give the merchant this secret", "ok");
      // The secret is shown once (the merchant needs it for charges).
      if (m.secret) alert("Mandate secret (share with the merchant once):\n\n" + m.secret);
      refresh();
    } catch (e) { toast("Authorize failed: " + e.message, "error"); }
  };
  refresh();
}

// FEAT-246 — transaction history screen.
async function screenHistory(id) {
  const acct = getAccount(id);
  if (!acct) return go("picker");
  h(`<h2>History</h2>
     <div id="entries"><p class="muted">Loading…</p></div>
     <div id="hist-nav" style="display:none">
       <button id="older">Older</button>
     </div>
     <a href="#account/${esc(id)}">Back</a>`);

  let beforeId = null;
  const load = async () => {
    try {
      const url = `/accounts/${id}/history` + (beforeId ? `?before=${beforeId}` : "");
      const r = await api(url, { key: acct.key });
      const entries = r.entries || [];
      if (entries.length === 0 && !beforeId) {
        document.getElementById("entries").innerHTML = "<p class='muted'>No transactions yet.</p>";
        return;
      }
      const rows = entries.map(e => {
        const dir = e.direction === "in" ? "+" : "−";
        const sat = Math.round(Math.abs(e.amount_msat) / 1000).toLocaleString();
        const label = esc(e.message || e.peer || e.payment_hash.slice(0, 12));
        const ts = e.ts ? new Date(e.ts).toLocaleString() : "";
        const cls = e.direction === "in" ? "color:green" : "color:#c00";
        return `<div class="card" style="padding:.4em .8em">
          <span style="${cls}">${dir}${sat} sat</span>
          <span class="muted" style="float:right;font-size:.85em">${ts}</span>
          <br><span class="muted" style="font-size:.85em">${label}</span>
        </div>`;
      }).join("");
      const box = document.getElementById("entries");
      if (beforeId) box.innerHTML += rows;
      else box.innerHTML = rows;
      if (r.has_more && entries.length) {
        beforeId = entries[entries.length - 1].id;
        document.getElementById("hist-nav").style.display = "";
      } else {
        document.getElementById("hist-nav").style.display = "none";
      }
    } catch (e) { document.getElementById("entries").innerHTML = `<p class="error">${esc(e.message)}</p>`; }
  };
  document.getElementById("older").onclick = load;
  await load();
}

function route() {
  if (POLL) { clearInterval(POLL); POLL = null; }
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
    case "history": return screenHistory(arg);
    case "referrals": return screenReferrals(arg);
    case "commerce": return screenCommerce(arg);
    case "pos": return screenPOS(arg);
    case "transfer": return screenTransfer(arg);
    case "so": return screenStandingOrders(arg);
    case "mandates": return screenMandates(arg);
    case "user-register": return screenUserRegister();
    case "user-login": return screenUserLogin();
    case "user": return screenUser();
    default: return screenPicker();
  }
}

window.addEventListener("hashchange", route);

(async function main() {
  await loadConfig();
  consumeInviteParam();
  document.getElementById("apibase").textContent = "API: " + CONFIG.api_base;
  route();
})();
