// unsyk admin panel. Talks only to /admin/api/* (admin cookie). Every value from the server is escaped
// through html``; widths are set through the CSSOM because the CSP forbids inline style attributes.
"use strict";

// ---------------- tiny helpers ----------------
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const RAW = Symbol("raw");
const raw = s => ({ [RAW]: true, s: String(s) });
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const emit = v => v == null || v === false ? "" : Array.isArray(v) ? v.map(emit).join("") : v[RAW] ? v.s : esc(v);
function html(str, ...vals) { let o = str[0]; vals.forEach((v, i) => { o += emit(v) + str[i + 1]; }); return raw(o); }
const put = (el, h) => { el.innerHTML = h.s; widths(el); return el; };
function widths(el) {
  $$("[data-w]", el).forEach(x => { x.style.width = x.dataset.w + "%"; });
  $$("[data-l]", el).forEach(x => { x.style.left = x.dataset.l + "%"; });
  $$("[data-h]", el).forEach(x => { x.style.height = x.dataset.h + "%"; });
}
const now = () => Date.now() / 1000;
const hm = ts => ts ? new Date(ts * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "";
const day = ts => ts ? new Date(ts * 1000).toLocaleDateString([], { day: "numeric", month: "short" }) : "";
const when = ts => ts ? `${day(ts)} ${hm(ts)}` : "–";
const ago = ts => { if (!ts) return "never"; const s = now() - ts; return s < 60 ? "just now" : s < 3600 ? `${Math.round(s / 60)} min ago` : s < 86400 ? `${Math.round(s / 3600)} h ago` : `${Math.round(s / 86400)} d ago`; };
const left = ts => { if (!ts) return "never expires"; const d = (ts - now()) / 86400; return d < 0 ? `expired ${day(ts)}` : d < 1 ? `${Math.max(1, Math.round(d * 24))} h left` : `${Math.floor(d)} days left`; };

class Unauthed extends Error {}
async function api(method, path, body) {
  const opt = { method, headers: { "X-Panel": "1" }, credentials: "same-origin" };
  if (body !== undefined) { opt.headers["Content-Type"] = "application/json"; opt.body = JSON.stringify(body); }
  const r = await fetch("/admin/api/" + path, opt);
  if (r.status === 401 && path !== "login") { showSignin(); throw new Unauthed(); }
  const ct = r.headers.get("Content-Type") || "";
  const out = ct.includes("json") ? await r.json().catch(() => ({})) : await r.text();
  if (!r.ok) throw new Error((out && out.error) || `error ${r.status}`);
  return out;
}
let toastT = 0;
function toast(msg, bad) {
  const t = $("#toast"); t.textContent = msg; t.className = "toast on" + (bad ? " bad" : "");
  clearTimeout(toastT); toastT = setTimeout(() => { t.className = "toast" + (bad ? " bad" : ""); }, bad ? 6000 : 3200);
}
const fail = e => { if (!(e instanceof Unauthed)) toast(e.message || String(e), true); };
async function copy(text, what = "Copied") {
  try { await navigator.clipboard.writeText(text); toast(what); }
  catch { const ta = document.createElement("textarea"); ta.value = text; document.body.append(ta); ta.select();
    try { document.execCommand("copy"); toast(what); } catch { toast("Select and copy by hand", true); } ta.remove(); }
}
function dialog(h, onSubmit) {
  const d = $("#dlg"); put(d, h);
  d.onclick = e => { if (e.target === d || e.target.closest("[data-close]")) d.close(); };
  const f = $("form", d);
  if (f) f.onsubmit = async e => { e.preventDefault(); const b = $("[type=submit]", f); if (b) b.disabled = true;
    try { await onSubmit(new FormData(f), d); } catch (err) { fail(err); } finally { if (b) b.disabled = false; } };
  d.showModal(); $("input,select,textarea,button[type=submit]", d)?.focus();
  return d;
}
function confirmBox(title, text, okLabel, danger) {
  return new Promise(res => {
    const d = dialog(html`<form method="dialog"><div class="dlg-h"><h2>${title}</h2><p>${text}</p></div>
      <div class="dlg-f"><button class="btn" type="button" data-close>Cancel</button>
      <button class="btn ${danger ? "btn--danger" : "btn--primary"}" type="submit">${okLabel}</button></div></form>`, async (_f, dd) => { done = true; dd.close(); res(true); });
    let done = false; d.addEventListener("close", () => { if (!done) res(false); }, { once: true });
  });
}

// ---------------- state ----------------
const st = {
  ws: "t", page: "compare", arg: "", roster: null, acct: "", sess: "latest", S: null, lic: [], presets: [], schema: {}, preSel: null, draft: null, dirty: false,
  lib: [], libSel: null, libItem: null, libCmp: "", edits: {}, lastId: 0, licFilter: "all", licQ: "", libQ: "", dlQ: "",
};
try { st.acct = localStorage.getItem("acct") || ""; } catch {}

// ---------------- remote-control keys: labels and groups ----------------
const KEYINFO = {
  enabled: "Anti-aim on", pitch: "Pitch", up_fix: "Level pitch when target is above", yaw_off: "Yaw offset", yaw_mod: "Yaw modifier",
  mod_amt: "Modifier amount", lag: "Fake lag (ticks)", lag_var: "Fake lag variance %", anim: "Animation",
  inverter: "Inverter", lim_stand: "Desync limit, standing", lim_move: "Desync limit, moving", lim_air: "Desync limit, in air",
  lim_duck: "Desync limit, crouched", lim_rnd: "Randomise limits", delay: "Flip delay (ticks)", delay_rnd: "Flip delay random ±",
  def_on: "Defensive burst", def_trig: "Trigger", def_int: "Interval (ms)", def_len: "Burst length (ticks)", def_shift: "Tick shift",
  def_pitch: "Burst pitch", def_yaw: "Burst yaw", def_flip: "Flip desync in burst", def_lag: "Max fake lag in burst",
  def_unch: "Unchoke after burst", def_rand: "Randomise burst",
  os_on: "On-shot anti-aim", os_mode: "On-shot mode", os_len: "On-shot length (ticks)", os_unch: "Unchoke on shot",
  peek_mode: "Peek mode", peek_len: "Peek hold (ticks)",
  dodge: "Dodge AA", dodge_rate: "Reroll every (ms)", dodge_min: "Desync minimum", dodge_max: "Desync maximum", dodge_asym: "Asymmetric left/right",
  dodge_yaw: "Yaw jitter", dodge_pitch: "Pitch flicks", dodge_swing: "Swing every (ms)", dodge_shift: "Swing tick shift",
  dodge_range: "Threat range (studs)", dodge_hit: "Swing when hit",
  flick: "Flick (needs DT off)", flick_rate: "Flick every (ticks)", flick_ticks: "Flick length (ticks)", flick_ang: "Flick angle",
  flick_side: "Flick side", flick_speed: "Flick max speed (0 = off)", flick_choke: "Flick only while choking",
  flick_unch: "Unchoke on flick", flick_lag: "Flick fake lag (ticks)",
  rs_mode: "Resolver", rs_lead: "Lead (ticks, -1 = ping)", rs_take: "Take over after misses", rs_max: "Largest desync guess",
  rs_baim: "Body aim after misses", rs_multi: "Candidate resolver", rs_pitch: "Force their usual pitch", rs_fd: "Safe point on fake duck",
  hc_air: "Hit chance in air", hc_noscope: "Hit chance unscoped", hc_duck: "Hit chance crouched", mindmg: "Minimum damage floor", lethal: "Lethal shots only",
  hc_move: "Hit chance while moving",
  ns: "No-spread mode", ns_hc: "No-spread hit chance", ns_md: "No-spread min damage (0 = lethal)", ns_half: "No-spread: half hp with DT weapon",
  ns_baim: "No-spread: no baim after misses",
  qs: "Quick stop", qs_how: "Quick stop method", qs_keep: "Quick stop: keep speed %", qs_hold: "Quick stop: max hold (ms)",
  qs_rest: "Quick stop: rest after shot (ms)",
  style: "AA style", style_lim: "Static desync (0 = off)", style_side: "Static side", style_swap: "Swap every (s)",
  style_jit: "Swap jitter (%)", style_lag: "Keep fake lag in No AA",
  roll: "Roll", roll_amt: "Roll amount (%)", roll_rate: "Roll jitter rate (ticks)", roll_when: "Roll when",
  fpitch: "Fake pitch", fpitch_val: "Fake pitch value (custom)", fpitch_off: "Fake pitch offset", fpitch_rate: "Fake pitch jitter rate (ticks)",
  rs_roll: "Anti-roll: counter", rs_lean: "Anti-roll: lean threshold", rs_pbrute: "Pitch brute force", rs_pmiss: "Pitch brute: misses before next",
};
const GROUPS = [
  ["Style", /^style/], ["Roll + fake pitch", /^(roll|fpitch)/], ["Anti-aim", /^(enabled|pitch|up_fix|yaw_|mod_|lag|anim)/], ["Desync", /^(inverter|lim_|delay)/], ["Defensive", /^def_/],
  ["On-shot", /^os_/], ["Peek", /^peek_/], ["Dodge", /^dodge/], ["Flick", /^flick/], ["Resolver", /^rs_/], ["Rage", /^(hc_|mindmg|lethal)/], ["No spread", /^ns/], ["Quick stop", /^qs/],
];

// ---------------- sign in ----------------
function showSignin() {
  stopTimers(); $("#app").hidden = true; $("#signin").hidden = false;
  setTimeout(() => ($("#si-user").value ? $("#si-pass") : $("#si-user")).focus(), 50);
}
$("#signin-form").addEventListener("submit", async e => {
  e.preventDefault();
  const err = $("#si-err"), go = $("#si-go"); err.textContent = ""; go.disabled = true; go.textContent = "Checking…";
  try {
    await api("POST", "login", { user: $("#si-user").value, password: $("#si-pass").value, code: $("#si-code").value });
    $("#si-pass").value = ""; $("#si-code").value = "";
    await boot();
  } catch (x) { err.textContent = x.message; $("#si-code").value = ""; $("#si-code").focus(); }
  finally { go.disabled = false; go.textContent = "Sign in"; }
});
$("#si-code").addEventListener("input", e => { e.target.value = e.target.value.replace(/\D/g, "").slice(0, 6);
  if (e.target.value.length === 6 && $("#si-pass").value) $("#signin-form").requestSubmit(); });

async function boot() {
  let me;
  try { me = await api("GET", "me"); } catch (e) { if (!(e instanceof Unauthed)) { $("#si-err").textContent = e.message; showSignin(); } return; }
  $("#who").textContent = me.user; $("#signin").hidden = true; $("#app").hidden = false;
  route(); startTimers();
}
$("#signout").onclick = async () => { try { await api("POST", "logout", {}); } catch {} showSignin(); };

// ---------------- shell ----------------
// Two workspaces. Testing = A/B results, build health, sessions, live, overrides (scoped to the test accounts:
// the beta members by default, or any accounts picked in the filter bar). Players = roster with licenses, one
// profile per player, saved configs, official presets, served copies.
const WS = {
  t: { name: "Testing", pages: [
    ["compare", "Compare", "ico-bars", "Config versions or builds side by side: deaths per minute with its error range, K/D and hit rate."],
    ["builds", "Builds", "ico-code", "Stable and beta: errors, stops and play results per build. Promote, roll back, pick the testers."],
    ["sessions", "Sessions", "ico-stack", "Every play session of the test accounts. Open one for its deaths, report and export."],
    ["live", "Live", "ico-pulse", "What is happening in game right now."],
    ["overrides", "Overrides", "ico-sliders", "Push settings to players while they play. The game applies them within about 5 seconds."],
  ] },
  p: { name: "Players", pages: [
    ["players", "Players", "ico-people", "Who is in game, how everyone plays, and their license."],
    ["configs", "Player configs", "ico-stack", "Every config your subscribers saved to the cloud, with its share code."],
    ["presets", "Official presets", "ico-star", "Configs every subscriber sees first in the in-game Configs page and can load."],
    ["downloads", "Served copies", "ico-key", "Every copy of the script that was downloaded. A leaked file names its source."],
  ] },
};
const HIDDEN = { session: ["t", "Session", "One play session: where the deaths came from, the full report and the raw data."],
  player: ["p", "Player", ""] };
const OLD = { overrides: "t/overrides", live: "t/live", stats: "t/sessions", script: "t/builds", presets: "p/presets",
  library: "p/configs", licenses: "p/players" };
function parseHash() {
  let h = (location.hash || "").slice(1);
  if (OLD[h]) h = OLD[h];
  const [ws, page, ...rest] = h.split("/");
  const arg = rest.length ? decodeURIComponent(rest.join("/")) : "";
  if (WS[ws] && (WS[ws].pages.some(p => p[0] === page) || (HIDDEN[page] && HIDDEN[page][0] === ws && arg))) return { ws, page, arg };
  return { ws: "t", page: "compare", arg: "" };
}
const go = h => { location.hash = h; };
function route() {
  const r = parseHash(); st.ws = r.ws; st.page = r.page; st.arg = r.arg;
  const W = WS[r.ws];
  $$(".ws a").forEach(a => a.setAttribute("aria-selected", String(a.dataset.ws === r.ws)));
  put($("#side-nav"), html`${W.pages.map(([id, lab, ico]) => html`<a href="#${r.ws}/${id}" ${raw(id === r.page ? 'aria-current="page"' : "")}><span class="ico ${ico}"></span>${lab}</a>`)}`);
  const meta = W.pages.find(p => p[0] === r.page) || [r.page, HIDDEN[r.page][1], "", HIDDEN[r.page][2]];
  const title = r.page === "player" ? r.arg : meta[1];
  $("#page-title").textContent = title; $("#page-sub").textContent = meta[3];
  document.title = `${title} · ${W.name} · unsyk admin`;
  $("#top-tools").innerHTML = ""; $("#fbar").hidden = true; $("#fbar").innerHTML = "";
  $("#page").innerHTML = ""; $("#page").style.animation = "none"; void $("#page").offsetWidth; $("#page").style.animation = "";
  closeSide(); $(".dock")?.remove(); $$(".menu-pop").forEach(m => m.remove());
  ({ compare: pCompare, builds: pBuilds, sessions: pSessions, session: pSession, live: pLive, overrides: pOverrides,
    players: pPlayers, player: pPlayer, configs: pLibrary, presets: pPresets, downloads: pDownloads })[r.page]();
}
window.addEventListener("hashchange", () => {
  if (st.dirty && !confirm("Leave without saving this preset?")) { history.replaceState(null, "", "#p/presets"); return; }
  st.dirty = false; route();
});
window.addEventListener("beforeunload", e => { if (st.dirty || Object.keys(st.edits).length) e.preventDefault(); });
function openSide() { $("#side").classList.add("open"); $("#scrim").hidden = false; $("#menu-btn").setAttribute("aria-expanded", "true"); }
function closeSide() { $("#side").classList.remove("open"); $("#scrim").hidden = true; $("#menu-btn").setAttribute("aria-expanded", "false"); }
$("#menu-btn").onclick = openSide; $("#side-close").onclick = closeSide; $("#scrim").onclick = closeSide;
$("#theme").onclick = () => {
  const cur = document.documentElement.dataset.theme || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  const next = cur === "dark" ? "light" : "dark"; document.documentElement.dataset.theme = next;
  try { localStorage.setItem("theme", next); } catch {}
};
try { const t = localStorage.getItem("theme"); if (t) document.documentElement.dataset.theme = t; } catch {}

// polling: only while the tab is visible, so a forgotten background tab lets the admin session idle out
const timers = [];
function startTimers() {
  stopTimers();
  timers.push(setInterval(() => { if (!document.hidden && ["overrides", "live"].includes(st.page)) loadStatus().then(rerender).catch(fail); }, 10000));
  timers.push(setInterval(() => { if (!document.hidden && st.page === "live") pollLive().catch(() => {}); }, 2500));
  timers.push(setInterval(() => { if (!document.hidden && st.page === "players" && !$(".menu-pop")) loadPlayers().catch(() => {}); }, 15000));
}
function stopTimers() { while (timers.length) clearInterval(timers.pop()); }
async function loadStatus() {
  st.S = await api("GET", `status?session=${encodeURIComponent(st.sess)}&acct=${encodeURIComponent(st.acct)}`);
  const age = st.S.last_event ? now() - st.S.last_event : 1e9;
  $("#feed-dot").className = "dot" + (age < 20 ? " dot--on" : "");
  return st.S;
}
function rerender() { if (st.page === "overrides") drawOverrides(); if (st.page === "live") drawLive(); }
function setAcct(a) {
  if (Object.keys(st.edits).length && !confirm("Drop the changes you have not pushed yet?")) return false;
  st.acct = a; st.sess = "latest"; st.lastId = 0; st.edits = {};
  try { localStorage.setItem("acct", a); } catch {}
  return true;
}
function accounts() {
  const names = new Map();
  (st.S?.accounts || []).forEach(a => names.set(a.acct, { acct: a.acct, user: a.user, online: !!(a.state?.ts && now() - a.state.ts < 20) }));
  st.lic.forEach(k => { if (!names.has(k.name)) names.set(k.name, { acct: k.name, user: k.user, online: k.online }); });
  return [...names.values()].sort((a, b) => (b.online - a.online) || a.acct.localeCompare(b.acct));
}
function scopeSeg(onPick) {
  const wrap = document.createElement("div"); wrap.className = "seg"; wrap.setAttribute("role", "group"); wrap.setAttribute("aria-label", "Account");
  const draw = () => put(wrap, html`<button type="button" data-a="" aria-pressed="${!st.acct}">Everyone</button>${accounts().map(a =>
    html`<button type="button" data-a="${a.acct}" aria-pressed="${st.acct === a.acct}"><span class="dot ${a.online ? "dot--on" : ""}"></span>${a.acct}</button>`)}`);
  wrap.onclick = e => { const b = e.target.closest("button[data-a]"); if (b && setAcct(b.dataset.a)) { draw(); onPick(); } };
  draw(); wrap.redraw = draw; return wrap;
}
async function loadLic() { st.lic = (await api("GET", "licenses")).keys; }

// ---------------- shared bits for the new views ----------------
// a segmented control as an element: opts = [[value, label], ...]
function segEl(opts, cur, onPick, label) {
  const w = document.createElement("div"); w.className = "seg"; w.setAttribute("role", "group"); if (label) w.setAttribute("aria-label", label);
  const draw = v => put(w, html`${opts.map(([val, lab]) => html`<button type="button" data-v="${val}" aria-pressed="${val === v}">${lab}</button>`)}`);
  w.onclick = e => { const b = e.target.closest("button[data-v]"); if (b) { draw(b.dataset.v); onPick(b.dataset.v); } };
  draw(cur); return w;
}
function selEl(opts, cur, onPick, label) {
  const s = document.createElement("select"); s.className = "inp"; if (label) s.setAttribute("aria-label", label);
  put(s, html`${opts.map(([v, l]) => html`<option value="${v}" ${raw(v === cur ? "selected" : "")}>${l}</option>`)}`);
  s.onchange = () => onPick(s.value); return s;
}
const RANGES = [["24h", "Last 24 h"], ["7d", "Last 7 days"], ["30d", "Last 30 days"], ["all", "All time"]];
const f2 = v => v == null ? "–" : (+v).toFixed(2);
const pct = v => v == null ? "–" : v + "%";
const mins = m => m == null ? "–" : m >= 90 ? `${(m / 60).toFixed(1)} h` : `${Math.round(m)} min`;
const kdOf = x => x.deaths ? (x.kills / x.deaths).toFixed(2) : (x.kills ? "∞" : "–");
function rateZ(d1, m1, d2, m2) {
  if (!(m1 > 0 && m2 > 0)) return null;
  return (d1 / m1 - d2 / m2) / Math.sqrt(Math.max(d1, 1) / m1 ** 2 + Math.max(d2, 1) / m2 ** 2);
}
function bKey(b, ch) { return b == null ? "" : (ch === "beta" ? "beta " : "") + "#" + b; }

// roster (players + licenses), used for the account chips and online dots
async function loadRoster(force) { if (!st.roster || force) st.roster = (await api("GET", "players?since=7d")).players; return st.roster; }
const onlineOf = a => !!(st.roster || []).find(p => p.acct === a && p.online);

// testing scope: accounts (null = the beta members), range, server kind. Kept in localStorage.
const TF = { accts: null, since: "7d", srv: "all" };
try { Object.assign(TF, JSON.parse(localStorage.getItem("tfilter") || "{}")); } catch {}
const saveTF = () => { try { localStorage.setItem("tfilter", JSON.stringify(TF)); } catch {} };
const testAccts = () => TF.accts || (st.roster || []).filter(p => p.beta).map(p => p.acct);
const tq = (extra = "") => `since=${TF.since}&accts=${encodeURIComponent(testAccts().join(","))}&srv=${TF.srv}${extra}`;
async function filterBar(onChange, opt = {}) {
  await loadRoster().catch(fail);
  const bar = $("#fbar"); bar.hidden = false;
  const seg = (k, opts) => html`<div class="seg seg--sm" role="group">${opts.map(([v, l]) => html`<button type="button" data-fk="${k}" data-fv="${v}" aria-pressed="${TF[k] === v}">${l}</button>`)}</div>`;
  const draw = () => {
    const sel = testAccts(), others = (st.roster || []).filter(p => !sel.includes(p.acct));
    put(bar, html`${opt.noAccts ? "" : html`<div class="fb-g"><span class="fb-l">Accounts</span>
      ${sel.length ? sel.map(a => html`<button type="button" class="chip" data-rm="${a}" title="Leave ${a} out"><span class="dot ${onlineOf(a) ? "dot--on" : ""}"></span>${a}<b aria-hidden="true">×</b></button>`)
        : html`<span class="chip chip--all">everyone</span>`}
      <select class="inp inp--sm" id="fb-add" aria-label="Add an account"><option value="">+ add account</option>${others.map(p => html`<option value="${p.acct}">${p.acct}${p.beta ? " (beta)" : ""}</option>`)}</select>
      ${TF.accts ? html`<button type="button" class="link-btn fine" id="fb-reset" title="Back to the accounts in the beta">reset to beta testers</button>` : html`<span class="fine muted">${sel.length ? "= beta testers" : ""}</span>`}</div>`}
      <div class="fb-g"><span class="fb-l">Range</span>${seg("since", [["24h", "24 h"], ["7d", "7 days"], ["30d", "30 days"], ["all", "all"]])}</div>
      ${opt.noSrv ? "" : html`<div class="fb-g"><span class="fb-l">Server</span>${seg("srv", [["all", "all"], ["nospread", "no spread"], ["spread", "spread"]])}</div>`}
      ${opt.note ? html`<span class="fine muted">${opt.note}</span>` : ""}`);
  };
  bar.onclick = e => {
    const rm = e.target.closest("[data-rm]"), sb = e.target.closest("[data-fk]");
    if (rm) TF.accts = testAccts().filter(x => x !== rm.dataset.rm);
    else if (sb) TF[sb.dataset.fk] = sb.dataset.fv;
    else if (e.target.id === "fb-reset") TF.accts = null;
    else return;
    saveTF(); draw(); onChange();
  };
  bar.onchange = e => { if (e.target.id === "fb-add" && e.target.value) { TF.accts = [...testAccts(), e.target.value]; saveTF(); draw(); onChange(); } };
  draw();
}

// ================= LIVE OVERRIDES =================
async function pOverrides() {
  put($("#page"), html`<div class="grid"><div class="stack"><div id="ov-call"></div><div class="card" id="ov"></div></div>
    <div class="stack"><div class="card"><div class="card-h"><h2>Who has their own overrides</h2></div><div class="card-b" id="ov-who"></div></div>
    <div class="card"><div class="card-h"><h2>Recent pushes</h2></div><div class="card-b card-b--flush" id="ov-log"></div></div></div></div>`);
  const dock = document.createElement("div"); dock.className = "dock";
  put(dock, html`<b id="dk-n"></b><input class="inp" id="dk-note" maxlength="200" placeholder="Why this change (shows in the game console and reports)">
    <button class="btn" type="button" id="dk-x">Discard</button><button class="btn btn--primary" type="button" id="dk-go">Push</button>`);
  document.body.append(dock);
  $("#dk-x").onclick = () => { st.edits = {}; drawOverrides(); };
  $("#dk-go").onclick = () => pushOverrides();
  try { await Promise.all([loadStatus(), loadLic()]); } catch (e) { return fail(e); }
  const seg = scopeSeg(async () => { await loadStatus().catch(fail); drawOverrides(); });
  const clr = document.createElement("button"); clr.className = "btn btn--danger btn--sm"; clr.type = "button"; clr.textContent = "Clear all overrides";
  clr.onclick = async () => {
    if (await confirmBox(st.acct ? `Clear ${st.acct}'s overrides?` : "Clear everyone's overrides?",
      st.acct ? "Their own overrides go away; the everyone layer still applies to them." : "The everyone layer goes away; accounts' own overrides stay.", "Clear", true))
      pushOverrides({ action: "clear" });
  };
  $("#top-tools").append(seg, clr);
  drawOverrides();
}
function drawOverrides() {
  const S = st.S; if (!S || !$("#ov")) return;
  if (document.activeElement?.closest?.("#ov")) return; // never redraw under the cursor
  const C = S.config || {}, set = C.set || {}, inh = C.everyone || {}, scoped = !!st.acct;
  // what the games really have (settings events): scoped = that account, everyone = every game seen in the last 15 min
  const LV = S.live_vals || {}, mine = scoped ? LV[st.acct] : null;
  const fresh = Object.entries(LV).filter(([, x]) => x && x.ts && now() - x.ts < 900);
  const fmtv = v => v === true ? "on" : v === false ? "off" : String(v);
  const liveOf = k => {
    if (scoped) return mine && k in (mine.vals || {}) ? { v: mine.vals[k], own: (mine.own || {})[k] } : null;
    const by = new Map(); fresh.forEach(([a, x]) => { if (k in (x.vals || {})) { const s = fmtv(x.vals[k]); by.set(s, [...(by.get(s) || []), a]); } });
    if (!by.size) return null;
    const list = [...by.entries()].map(([s, as]) => `${s}: ${as.join(", ")}`).join("\n");
    return by.size === 1 ? { v: fresh.find(([, x]) => k in (x.vals || {}))[1].vals[k], who: list } : { mixed: true, who: list };
  };
  const ctl = (k, spec, v, lv) => {
    if (spec.t === "b") return html`<div class="tri" role="group" aria-label="${KEYINFO[k] || k}">${[["", "Unset"], ["true", "On"], ["false", "Off"]].map(([val, lab]) =>
      html`<button type="button" data-k="${k}" data-v="${val}" aria-pressed="${(v === undefined ? "" : String(v)) === val}">${lab}</button>`)}</div>`;
    if (spec.t === "c") return html`<select data-k="${k}" aria-label="${KEYINFO[k] || k}"><option value="">${lv && !lv.mixed ? `Not set (game: ${fmtv(lv.v)})` : "Not set"}</option>${spec.o.map(o =>
      html`<option value="${o}" ${raw(v === o ? "selected" : "")}>${o}</option>`)}</select>`;
    const mid = Math.round((spec.lo + spec.hi) / 2), gv = lv && typeof lv.v === "number" ? Math.round(lv.v) : null;
    return html`<input type="range" data-k="${k}" min="${spec.lo}" max="${spec.hi}" step="1" value="${v ?? gv ?? mid}" aria-label="${KEYINFO[k] || k}">
      <input type="number" data-k="${k}" min="${spec.lo}" max="${spec.hi}" step="1" value="${v ?? ""}" placeholder="${gv ?? "–"}" aria-label="${(KEYINFO[k] || k) + " value"}">`;
  };
  let body = [];
  for (const [g, re] of GROUPS) {
    const keys = Object.keys(S.keys).filter(k => re.test(k)); if (!keys.length) continue;
    const n = keys.filter(k => k in set).length;
    body.push(html`<section class="kgroup"><div class="kgroup-h"><h3>${g}</h3>${n ? html`<span class="pill pill--acc">${n} on</span>` : ""}</div>${keys.map(k => {
      const spec = S.keys[k], over = k in set, dirty = k in st.edits, fromAll = scoped && !over && k in inh;
      const giving = dirty && st.edits[k] === null;
      const v = dirty ? (giving ? undefined : st.edits[k]) : over ? set[k] : undefined;
      const cls = dirty ? "is-dirty" : over ? "is-over" : fromAll ? "is-inh" : "";
      const lv = liveOf(k), want = over ? set[k] : fromAll ? inh[k] : undefined;
      // the game's value; amber when it does not match what the server says it should have (not applied yet)
      const off = lv && !lv.mixed && want !== undefined && fmtv(lv.v) !== fmtv(want);
      const game = !lv ? "" : lv.mixed ? html`<span class="pill pill--warn" title="${lv.who}">game: mixed</span>`
        : html`<span class="pill ${off ? "pill--warn" : "pill--good"}" title="${lv.who || (off ? "The game has not applied this yet (remote control off, or it polls within 5 s)" : "Value in the game right now")}">game: ${fmtv(lv.v)}</span>`;
      const ownV = lv && lv.own !== undefined ? html` <span class="fine muted">player's own: ${fmtv(lv.own)}</span>` : "";
      const state = dirty ? html`${giving ? html`<span class="pill pill--warn">give back</span>` : ""}<button class="btn btn--ghost btn--sm" type="button" data-undo="${k}">Undo</button>`
        : over ? html`${game}<button class="btn btn--ghost btn--sm" type="button" data-unset="${k}" title="Give the setting back to the player">Give back</button>`
        : fromAll ? html`${game}<span class="pill" title="From the everyone layer">all: ${String(inh[k])}</span>` : lv ? game : html`<span class="pill">player's</span>`;
      return html`<div class="krow ${cls}"><div class="klabel"><b>${KEYINFO[k] || k}</b><code>${k}${spec.t === "n" ? ` · ${spec.lo} to ${spec.hi}` : ""}</code>${over && scoped && k in inh ? html` <span class="fine muted">everyone: ${String(inh[k])}</span>` : ""}${ownV}</div>
        <div class="kctl">${ctl(k, spec, v, lv)}</div><div class="kstate">${state}</div></div>`;
    })}</section>`);
  }
  put($("#ov"), html`<div class="card-h"><div><h2>${scoped ? `Overrides for ${st.acct}` : "Overrides for everyone"}</h2>
    <p class="muted">${scoped ? "On top of the everyone layer. Dashed = inherited from everyone." : "Every player gets these unless their account overrides the same setting."} Config v${C.v || 0}.
    ${scoped ? (mine ? `Game values from ${st.acct}, ${ago(mine.ts)}${mine.cv != null ? ` (game on v${mine.cv})` : ""}.` : `No game values from ${st.acct} yet (needs the new build, sent every minute).`)
      : (fresh.length ? `Game values from ${fresh.length} game${fresh.length === 1 ? "" : "s"} seen in the last 15 min.` : "No game reported its values in the last 15 min.")}</p></div></div>${body}`);
  const remoteOff = S.state && S.state.remote === false && scoped;
  put($("#ov-call"), remoteOff ? html`<div class="callout callout--warn">Remote control is off in ${st.acct}'s game, so pushes will wait until they turn it on (Settings, Feed).</div>` : html``);
  const others = Object.entries(C.accounts || {}).filter(([, v]) => Object.keys(v).length);
  put($("#ov-who"), others.length ? html`<div class="bars">${others.map(([a, v]) => html`<div><b>${a}</b> <span class="muted fine">${Object.keys(v).join(", ")}</span></div>`)}</div>`
    : html`<p class="hint">${scoped ? "Pick Everyone to see this list." : "No account has its own overrides."}</p>`);
  put($("#ov-log"), S.ctrl_log.length ? html`<table><tbody>${S.ctrl_log.map(c => html`<tr><td class="num muted">${hm(c.ts)}</td><td>v${c.v}</td>
    <td class="fine">${Object.entries(c.applied || {}).map(([k, v]) => `${k}=${v}`).join(" ") || "–"}<span class="sub">${c.note || ""}</span></td></tr>`)}</tbody></table>`
    : html`<p class="empty">No pushes reached this game session yet.</p>`);
  const n = Object.keys(st.edits).length, dock = $(".dock");
  if (dock) { dock.classList.toggle("on", n > 0); $("#dk-n").textContent = `${n} change${n === 1 ? "" : "s"} for ${st.acct || "everyone"}`; }
}
document.addEventListener("click", e => {
  if (st.page !== "overrides") return;
  const b = e.target.closest("#ov [data-k][data-v]");
  if (b) { const k = b.dataset.k, v = b.dataset.v; const set = st.S.config.set || {};
    if (v === "") { if (k in set) st.edits[k] = null; else delete st.edits[k]; }
    else st.edits[k] = v === "true";
    if (k in st.edits && set[k] === st.edits[k]) delete st.edits[k];
    b.blur(); drawOverrides(); return; }
  const u = e.target.closest("#ov [data-unset]"); if (u) { st.edits[u.dataset.unset] = null; u.blur(); drawOverrides(); return; }
  const d = e.target.closest("#ov [data-undo]"); if (d) { delete st.edits[d.dataset.undo]; d.blur(); drawOverrides(); }
});
document.addEventListener("input", e => {
  const el = e.target; if (st.page !== "overrides" || !el.closest?.("#ov") || !el.dataset.k) return;
  const k = el.dataset.k, spec = st.S.keys[k];
  if (spec.t === "n") {
    const n = Number(el.value); const row = el.closest(".krow");
    if (el.value === "" || !Number.isFinite(n)) return;
    const v = Math.min(spec.hi, Math.max(spec.lo, Math.round(n)));
    $$(`[data-k="${k}"]`, row).forEach(x => { if (x !== el) x.value = v; });
    st.edits[k] = v; row.className = "krow is-dirty";
    const n2 = Object.keys(st.edits).length; $(".dock")?.classList.add("on"); $("#dk-n").textContent = `${n2} change${n2 === 1 ? "" : "s"} for ${st.acct || "everyone"}`;
  }
});
document.addEventListener("change", e => {
  const el = e.target; if (st.page !== "overrides" || !el.closest?.("#ov") || !el.dataset.k) return;
  const k = el.dataset.k, spec = st.S.keys[k];
  if (spec.t === "c") { const set = st.S.config.set || {};
    if (el.value === "") { if (k in set) st.edits[k] = null; else delete st.edits[k]; } else st.edits[k] = el.value;
    if (k in st.edits && set[k] === st.edits[k]) delete st.edits[k];
    el.blur(); drawOverrides(); }
  if (spec.t === "n") { el.blur(); drawOverrides(); }
});
async function pushOverrides(body) {
  // staged edits: null = give the setting back to the player, anything else = set it
  const note = $("#dk-note")?.value.trim() || "", acct = st.acct || undefined;
  const sets = Object.fromEntries(Object.entries(st.edits).filter(([, v]) => v !== null));
  const unsets = Object.keys(st.edits).filter(k => st.edits[k] === null);
  try {
    let r;
    if (body) r = await api("POST", "overrides", { ...body, note, acct });
    if (!body && unsets.length) r = await api("POST", "overrides", { action: "unset", keys: unsets, note, acct });
    if (!body && Object.keys(sets).length) r = await api("POST", "overrides", { action: "set", set: sets, note, acct });
    st.edits = {}; if ($("#dk-note")) $("#dk-note").value = "";
    toast(`Pushed v${r.v} to ${r.acct || "everyone"}. Games pick it up within about 5 s.`);
    await loadStatus(); document.activeElement?.blur?.(); drawOverrides();
  } catch (e) { fail(e); }
}

// ================= OFFICIAL PRESETS =================
const secOf = k => k.includes("/") ? k.split("/")[0] : "Other";
const itemOf = k => k.includes("/") ? k.split("/").slice(1).join("/") : k;
async function pPresets() {
  put($("#page"), html`<div class="grid grid--wide-left"><div class="stack"><div class="card"><div class="card-h"><h2>Published</h2><span class="muted fine" id="pr-n"></span></div>
    <div class="plist" id="pr-list"></div><div class="card-b"><button class="btn btn--primary btn--block" type="button" id="pr-new">New preset</button></div></div>
    <div class="card"><div class="card-h"><div><h2>Built into the script</h2><p class="muted">Shipped inside unsyk.lua, load-only in game.</p></div></div><div class="plist" id="pr-bi"></div></div>
    <p class="hint">Players see the published presets at the top of the in-game Configs list, marked official, in this order. Load only: players cannot change or delete them.
      A published preset with the same name as a built-in one replaces it in game (from build #10); the built-in copy is then only used when the server cannot be reached.</p></div>
    <div class="card" id="pr-ed"></div></div>`);
  $("#pr-new").onclick = () => newDraft({ name: "", note: "", data: {} });
  await loadPresets();
  if (st.preSel && st.presets.find(p => p.name === st.preSel)) selPreset(st.preSel); else if (st.presets[0]) selPreset(st.presets[0].name); else drawEditor();
}
async function loadPresets() {
  try { const r = await api("GET", "presets"); st.presets = r.presets; st.schema = r.schema; st.presetMax = r.max; st.builtin = r.builtin || []; } catch (e) { return fail(e); }
  drawPresetList();
}
function drawPresetList() {
  $("#pr-n").textContent = `${st.presets.length} of ${st.presetMax || 12}`;
  put($("#pr-list"), st.presets.length ? html`${st.presets.map((p, i) => html`<div class="pitem" role="button" tabindex="0" data-p="${p.name}" aria-current="${st.preSel === p.name && !st.draft?.isNew}">
    <b>${p.name}</b><span>${p.size} settings · ${day(p.ts)}${p.note ? " · " + p.note : ""}</span>
    <div class="ord"><button type="button" data-mv="-1" data-i="${i}" aria-label="Move up">↑</button><button type="button" data-mv="1" data-i="${i}" aria-label="Move down">↓</button></div></div>`)}`
    : html`<p class="empty">Nothing published yet. Make one, or publish a player's config from Player configs.</p>`);
  $("#pr-list").onclick = async e => {
    const mv = e.target.closest("[data-mv]");
    if (mv) { e.stopPropagation(); const i = +mv.dataset.i, j = i + +mv.dataset.mv; if (j < 0 || j >= st.presets.length) return;
      const names = st.presets.map(p => p.name); [names[i], names[j]] = [names[j], names[i]];
      try { await api("POST", "presets", { op: "order", names }); await loadPresets(); } catch (x) { fail(x); } return; }
    const it = e.target.closest("[data-p]"); if (it) selPreset(it.dataset.p);
  };
  $("#pr-list").onkeydown = e => { if (e.key === "Enter" && e.target.dataset.p) selPreset(e.target.dataset.p); };
  // built-in presets: on the server = it syncs (server copy wins in game); not yet = players get the script's copy
  const bi = st.builtin || [];
  put($("#pr-bi"), bi.length ? html`${bi.map(b => { const pub = st.presets.find(p => p.name === b.name);
    const nd = pub ? diffCount(b.data, pub.data) : 0;
    return html`<div class="pitem" role="button" tabindex="0" data-b="${b.name}" aria-current="${!!(st.draft?.isNew && st.draft.fromBuiltin === b.name)}">
      <b>${b.name}</b><span>${Object.keys(b.data).length} settings · ${pub ? (nd ? `published, ${nd} setting${nd === 1 ? "" : "s"} differ from the script's copy` : "published, same as the script's copy") : "not on the server: edits here do not reach the game until you publish it"}</span>
      <div class="ord">${pub ? html`<span class="pill pill--good">synced</span>` : html`<span class="pill pill--warn">script only</span>`}</div></div>`; })}`
    : html`<p class="empty">The deployed script reports no built-in presets.</p>`);
  const openB = name => { const b = bi.find(x => x.name === name); if (!b) return;
    if (st.presets.find(p => p.name === name)) return selPreset(name);
    newDraft({ name: b.name, note: "from the script's built-in preset", data: { ...b.data }, fromBuiltin: b.name }); };
  $("#pr-bi").onclick = e => { const it = e.target.closest("[data-b]"); if (it) openB(it.dataset.b); };
  $("#pr-bi").onkeydown = e => { if (e.key === "Enter" && e.target.dataset.b) openB(e.target.dataset.b); };
}
function diffCount(a, b) { return [...new Set([...Object.keys(a), ...Object.keys(b)])].filter(k => JSON.stringify(a[k]) !== JSON.stringify(b[k])).length; }
function selPreset(name) {
  if (st.dirty && !confirm("Drop the unsaved changes to this preset?")) return;
  const p = st.presets.find(x => x.name === name); if (!p) return;
  st.preSel = name; newDraft({ name: p.name, note: p.note, data: { ...p.data }, orig: p.name });
}
function newDraft(d) {
  if (st.dirty && d.orig === undefined && !confirm("Drop the unsaved changes to this preset?")) return;
  st.draft = { ...d, isNew: d.orig === undefined }; st.dirty = false; drawPresetList(); drawEditor();
}
function valueInput(k, v, attrs = "") {
  const t = typeof v;
  if (t === "boolean") return html`<select class="inp" data-dk="${k}" data-t="b" ${raw(attrs)}><option value="true" ${raw(v ? "selected" : "")}>On</option><option value="false" ${raw(!v ? "selected" : "")}>Off</option></select>`;
  if (t === "number") return html`<input class="inp mono" type="number" step="any" data-dk="${k}" data-t="n" value="${v}" ${raw(attrs)}>`;
  const opts = st.schema[k]?.o || [];
  return html`<input class="inp" data-dk="${k}" data-t="s" value="${v}" maxlength="64" list="dl-${k.replace(/[^\w]/g, "_")}" ${raw(attrs)}>
    <datalist id="dl-${k.replace(/[^\w]/g, "_")}">${opts.map(o => html`<option value="${o}"></option>`)}</datalist>`;
}
function groupedRows(data, rowFn) {
  const keys = Object.keys(data).sort((a, b) => secOf(a).localeCompare(secOf(b)) || a.localeCompare(b));
  let last = null; const out = [];
  for (const k of keys) { const s = secOf(k); if (s !== last) { out.push(html`<tr class="sec-row"><td colspan="3">${s}</td></tr>`); last = s; } out.push(rowFn(k)); }
  return out;
}
function drawEditor() {
  const ed = $("#pr-ed"), d = st.draft;
  if (!d) return put(ed, html`<p class="empty">Pick a preset on the left, or make a new one.</p>`);
  const missing = Object.keys(st.schema).filter(k => !(k in d.data));
  const bi = (st.builtin || []).find(b => b.name === (d.isNew ? d.name : d.orig));
  const biNote = !bi ? "" : d.isNew ? html`<div class="callout callout--warn">This is the script's built-in <b>${bi.name}</b>. Publish it so the server copy replaces the built-in in game; after that, edits here reach every player.</div>`
    : html`<div class="callout">Replaces the script's built-in <b>${bi.name}</b> in game. ${diffCount(bi.data, d.data)} settings differ from the built-in copy.</div>`;
  put(ed, html`<div class="card-h"><div><h2>${d.isNew ? (d.fromBuiltin ? "Built-in: " + d.fromBuiltin : "New preset") : d.orig}</h2><p class="muted">${Object.keys(d.data).length} settings${d.isNew ? (d.fromBuiltin ? " · not published yet" : "") : " · published"}</p></div>
    <div class="toolbar">${d.isNew ? "" : html`<button class="btn btn--sm" type="button" id="ed-dup">Duplicate</button><button class="btn btn--sm btn--danger" type="button" id="ed-del">Unpublish</button>`}
    <button class="btn btn--sm" type="button" id="ed-json">JSON</button><button class="btn btn--primary btn--sm" type="button" id="ed-save">${d.isNew ? "Publish" : "Save"}</button></div></div>
    ${biNote ? html`<div class="card-b">${biNote}</div>` : ""}<div class="editor-head"><label class="field"><span>Name players see</span><input class="inp" id="ed-name" maxlength="24" value="${d.name}" placeholder="e.g. Scout HvH"></label>
    <label class="field"><span>Note (admin only)</span><input class="inp" id="ed-note" maxlength="140" value="${d.note || ""}" placeholder="what it is for"></label></div>
    ${Object.keys(d.data).length ? html`<div class="table-wrap"><table class="vtable"><tbody>${groupedRows(d.data, k => html`<tr><td class="k"><code>${itemOf(k)}</code></td>
      <td>${valueInput(k, d.data[k])}</td><td class="r"><button class="btn btn--ghost btn--sm" type="button" data-rm="${k}" aria-label="Remove ${k}">Remove</button></td></tr>`)}</tbody></table></div>`
      : html`<p class="empty">No settings yet. Add them below, paste JSON, or publish a player's config from Player configs.</p>`}
    <div class="addrow"><input class="inp mono" id="ed-key" list="ed-keys" placeholder="Section/Item, e.g. Anti-aim/Pitch"><datalist id="ed-keys">${missing.map(k => html`<option value="${k}"></option>`)}</datalist>
    <button class="btn btn--sm" type="button" id="ed-add">Add setting</button></div>`);
  const mark = () => { st.dirty = true; };
  ed.oninput = e => {
    if (e.target.id === "ed-name") d.name = e.target.value; else if (e.target.id === "ed-note") d.note = e.target.value;
    else if (e.target.dataset.dk) { const k = e.target.dataset.dk, t = e.target.dataset.t, v = e.target.value;
      d.data[k] = t === "b" ? v === "true" : t === "n" ? (v === "" ? d.data[k] : Number(v)) : v; }
    else return; mark();
  };
  ed.onchange = ed.oninput;
  ed.onclick = async e => {
    const rm = e.target.closest("[data-rm]"); if (rm) { delete d.data[rm.dataset.rm]; mark(); return drawEditor(); }
    const id = e.target.closest("button")?.id;
    if (id === "ed-add") { const k = $("#ed-key").value.trim(); if (!k) return;
      if (k.length > 80) return toast("Keys are at most 80 characters", true);
      const t = st.schema[k]?.t; d.data[k] = t === "b" ? true : t === "n" ? 0 : (st.schema[k]?.o?.[0] ?? ""); mark(); drawEditor(); $("#ed-key").focus(); }
    if (id === "ed-save") {
      try { const r = await api("POST", "presets", { op: "save", name: d.name, note: d.note, data: d.data, rename_from: d.isNew ? undefined : d.orig });
        st.dirty = false; st.preSel = r.name; toast(`${r.name} is live for every player`); await loadPresets(); selPreset(r.name); } catch (x) { fail(x); } }
    if (id === "ed-dup") newDraft({ name: (d.name + " copy").slice(0, 24), note: d.note, data: { ...d.data } });
    if (id === "ed-del" && await confirmBox(`Unpublish ${d.orig}?`, "Players stop seeing it. Configs they already loaded stay in their game.", "Unpublish", true)) {
      try { await api("POST", "presets", { op: "delete", name: d.orig }); st.dirty = false; st.draft = null; st.preSel = null; toast("Unpublished"); await loadPresets(); drawEditor(); } catch (x) { fail(x); } }
    if (id === "ed-json") dialog(html`<form><div class="dlg-h"><h2>Settings as JSON</h2><p>Copy it, or paste a config here to replace the settings.</p></div>
      <div class="dlg-b"><textarea class="inp" name="j" spellcheck="false">${JSON.stringify(d.data, null, 1)}</textarea></div>
      <div class="dlg-f"><button class="btn" type="button" id="j-copy">Copy</button><button class="btn" type="button" data-close>Cancel</button><button class="btn btn--primary" type="submit">Replace settings</button></div></form>`,
      async (f, dd) => { const o = JSON.parse(f.get("j")); if (!o || typeof o !== "object" || Array.isArray(o)) throw new Error("needs a JSON object");
        d.data = o; mark(); dd.close(); drawEditor(); }) && ($("#j-copy").onclick = () => copy(JSON.stringify(d.data, null, 1), "JSON copied"));
  };
}

// ================= PLAYER CONFIGS =================
async function pLibrary() {
  put($("#page"), html`<div class="grid"><div class="card"><div class="card-h"><h2>Saved configs</h2><input class="inp search" id="lib-q" type="search" placeholder="Search name, player or code" value="${st.libQ}"></div>
    <div class="table-wrap" id="lib-t"></div></div><div class="card" id="lib-d"></div></div>`);
  $("#lib-q").oninput = e => { st.libQ = e.target.value; drawLib(); };
  try { const [lib, pr] = await Promise.all([api("GET", "library"), api("GET", "presets")]); st.lib = lib.configs; st.presets = pr.presets; st.schema = pr.schema; }
  catch (e) { return fail(e); }
  drawLib(); drawLibItem();
}
function drawLib() {
  const q = st.libQ.trim().toLowerCase();
  const rows = st.lib.filter(c => !q || [c.name, c.acct, c.code].some(x => String(x || "").toLowerCase().includes(q)));
  put($("#lib-t"), rows.length ? html`<table><thead><tr><th>Config</th><th>Player</th><th class="r">Settings</th><th>Code</th><th>Saved</th></tr></thead><tbody>${rows.map(c =>
    html`<tr class="click ${st.libSel && st.libSel.acct === c.acct && st.libSel.name === c.name ? "sel" : ""}" data-a="${c.acct}" data-n="${c.name}" tabindex="0">
      <td><b>${c.name}</b></td><td>${c.acct}</td><td class="r num">${c.size}</td><td><code>${c.code || "–"}</code></td><td class="muted">${ago(c.ts)}</td></tr>`)}</tbody></table>`
    : html`<p class="empty">${st.lib.length ? "Nothing matches." : "No player has saved a config yet."}</p>`);
  const open = tr => { st.libSel = { acct: tr.dataset.a, name: tr.dataset.n }; drawLib(); loadLibItem(); };
  $("#lib-t").onclick = e => { const tr = e.target.closest("tr[data-a]"); if (tr) open(tr); };
  $("#lib-t").onkeydown = e => { const tr = e.target.closest("tr[data-a]"); if (tr && e.key === "Enter") open(tr); };
}
async function loadLibItem() {
  try { st.libItem = await api("GET", `library/item?acct=${encodeURIComponent(st.libSel.acct)}&name=${encodeURIComponent(st.libSel.name)}`); }
  catch (e) { st.libItem = null; fail(e); }
  drawLibItem();
}
function drawLibItem() {
  const c = st.libItem, el = $("#lib-d");
  if (!c) return put(el, html`<p class="empty">Pick a config to see its settings, compare it with a preset, or publish it.</p>`);
  const cmp = st.presets.find(p => p.name === st.libCmp);
  const data = { ...c.data }; if (cmp) Object.keys(cmp.data).forEach(k => { if (!(k in data)) data[k] = undefined; });
  const nDiff = cmp ? Object.keys(data).filter(k => JSON.stringify(c.data[k]) !== JSON.stringify(cmp.data[k])).length : 0;
  const show = v => v === undefined ? "–" : typeof v === "boolean" ? (v ? "On" : "Off") : String(v);
  put(el, html`<div class="card-h"><div><h2>${c.name}</h2><p class="muted">by ${c.acct} · ${when(c.ts)} · code <code>${c.code || "–"}</code></p></div></div>
    <div class="card-b toolbar"><button class="btn btn--primary btn--sm" type="button" id="lib-pub">Publish as official</button>
    <button class="btn btn--sm btn--danger" type="button" id="lib-del">Delete</button>
    <select class="inp" id="lib-cmp" aria-label="Compare with"><option value="">Compare with a preset…</option>${st.presets.map(p => html`<option value="${p.name}" ${raw(p.name === st.libCmp ? "selected" : "")}>${p.name}</option>`)}</select></div>
    ${cmp ? html`<p class="hint card-b">${nDiff} of ${Object.keys(data).length} settings differ from ${cmp.name} (highlighted).</p>` : ""}
    <div class="table-wrap"><table class="vtable"><tbody>${groupedRows(data, k => {
      const diff = cmp && JSON.stringify(c.data[k]) !== JSON.stringify(cmp.data[k]);
      return html`<tr class="${diff ? "diff" : ""}"><td class="k"><code>${itemOf(k)}</code></td><td>${show(c.data[k])}</td><td class="muted">${cmp ? show(cmp.data[k]) : ""}</td></tr>`; })}</tbody></table></div>`);
  $("#lib-cmp").onchange = e => { st.libCmp = e.target.value; drawLibItem(); };
  $("#lib-del").onclick = async () => {
    if (!await confirmBox(`Delete ${c.name} by ${c.acct}?`, "It disappears from their in-game list and its share code stops working. This cannot be undone.", "Delete", true)) return;
    try { await api("POST", "library", { op: "delete", acct: c.acct, name: c.name }); toast("Deleted"); st.libSel = st.libItem = null; await pLibrary(); } catch (x) { fail(x); }
  };
  $("#lib-pub").onclick = () => dialog(html`<form><div class="dlg-h"><h2>Publish as official</h2><p>Every player will see it at the top of their Configs list. Same name replaces that preset.</p></div>
    <div class="dlg-b"><label class="field"><span>Name players see</span><input name="as" maxlength="24" value="${c.name}" required></label>
    <label class="field"><span>Note (admin only)</span><input name="note" maxlength="140" value="${"from " + c.acct}"></label></div>
    <div class="dlg-f"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn--primary" type="submit">Publish</button></div></form>`,
    async (f, dd) => { const r = await api("POST", "library", { op: "publish", acct: c.acct, name: c.name, as: f.get("as"), note: f.get("note") });
      dd.close(); toast(`${r.name} is live for every player`); st.preSel = r.name; });
}

// ================= LIVE =================
async function pLive() {
  put($("#page"), html`<div class="stack"><div class="tiles" id="lv-tiles"></div><div class="grid"><div class="card"><div class="card-h"><h2>Events</h2><span class="muted fine" id="lv-age"></span></div>
    <div class="feed" id="lv-feed" aria-live="off"></div></div><div class="stack"><div class="card"><div class="card-h"><h2>In game now</h2></div><div class="card-b"><dl class="kv" id="lv-now"></dl></div></div>
    <div class="card"><div class="card-h"><h2>Last deaths</h2></div><div class="card-b card-b--flush" id="lv-d"></div></div></div></div></div>`);
  st.lastId = 0;
  try { await Promise.all([loadStatus(), loadLic()]); } catch (e) { return fail(e); }
  const seg = scopeSeg(async () => { $("#lv-feed").innerHTML = ""; await loadStatus().catch(fail); drawLive(); pollLive(); });
  const sel = document.createElement("select"); sel.className = "inp"; sel.id = "lv-sess"; sel.setAttribute("aria-label", "Session");
  sel.onchange = async () => { st.sess = sel.value; await loadStatus().catch(fail); drawLive(); };
  $("#top-tools").append(seg, sel); drawLive(); pollLive();
}
function tilesFor(T) {
  const kd = T.deaths ? (T.kills / T.deaths).toFixed(2) : (T.kills || "–");
  return html`${[["kills", T.kills], ["deaths", T.deaths], ["K/D", kd], ["deaths / min", T.alive_min > 0.5 ? (T.deaths / T.alive_min).toFixed(2) : "–"],
    ["shots landed", T.fired ? Math.round(T.landed / T.fired * 100) + "%" : "–"], ["one-shot deaths", T.deaths ? Math.round(T.one_shots / T.deaths * 100) + "%" : "–"],
    ["minutes alive", T.alive_min]].map(([k, v]) => html`<div class="tile"><b>${v}</b><span>${k}</span></div>`)}`;
}
function sessOptions(sel) {
  const cur = st.sess;
  put(sel, html`<option value="latest">Latest session</option>${st.S.sessions.map(x => html`<option value="${x.session}">${st.acct ? "" : x.acct + " · "}${day(x.a)} ${hm(x.a)}–${hm(x.b)} (${x.n})</option>`)}`);
  sel.value = cur;
}
function drawLive() {
  const S = st.S; if (!S || !$("#lv-tiles")) return;
  put($("#lv-tiles"), tilesFor(S.totals)); sessOptions($("#lv-sess"));
  const s = S.state || {}, my = s.my || {}, f = s.feed || {};
  $("#lv-age").textContent = S.last_event ? `last event ${ago(S.last_event)}` : "no events yet";
  put($("#lv-now"), html`${[["build", s.ver], ["health", s.hp ?? "?"], ["state", [s.my_state, s.phase].filter(Boolean).join(", ")],
    ["weapon", [my.wep, my.scoped ? "scoped" : ""].filter(Boolean).join(", ")], ["anti-aim", `${s.inv ?? "?"} · ${s.mod ?? "?"} · pitch ${s.pitch ?? "?"} · side ${s.side ?? "?"}${s.lim != null ? " · " + Math.round(s.lim) + "°" : ""}`],
    ["server", `${s.srv || "unknown"} · job ${s.job || "?"}`], ["remote", s.remote ? `on · config v${s.cv || 0}` : "off"],
    ["feed", f.sent != null ? `${f.sent} sent, ${f.failed} failed` : "?"], ["snapshot", s.ts ? ago(s.ts) : "none"]].map(([k, v]) => html`<dt>${k}</dt><dd>${v}</dd>`)}`);
  put($("#lv-d"), S.recent_deaths.length ? html`<table><tbody>${S.recent_deaths.map(d => html`<tr><td class="muted num">${hm(d.ts)}</td><td>${d.state || "?"} ${d.side || ""}<span class="sub">flip ${d.flip ?? "?"}t</span></td>
    <td>${d.killer || "?"}<span class="sub">${[d.kwep, d.kdist != null ? d.kdist + " st" : ""].filter(Boolean).join(" · ")}</span></td></tr>`)}</tbody></table>`
    : html`<p class="empty">No deaths in this session.</p>`);
}
async function pollLive() {
  const want = st.acct, d = await api("GET", `live?after=${st.lastId}&acct=${encodeURIComponent(st.acct)}`);
  const feed = $("#lv-feed"); if (!feed || want !== st.acct) return;
  if (d.events.length) {
    const stick = feed.scrollTop + feed.clientHeight >= feed.scrollHeight - 30;
    feed.insertAdjacentHTML("beforeend", d.events.map(e => { const m = e.line.match(/^(\S+)(.*)$/s) || ["", e.line, ""];
      return html`<div class="${e.cls}"><span class="t">${hm(e.ts)}</span> ${st.acct ? "" : html`<span class="t">${e.acct}</span> `}<span class="k">${m[1]}</span>${m[2]}</div>`.s; }).join(""));
    while (feed.children.length > 500) feed.firstChild.remove();
    if (stick) feed.scrollTop = feed.scrollHeight;
    if (d.events.some(e => e.cls !== "fire") && st.lastId) loadStatus().then(drawLive).catch(() => {});
  }
  st.lastId = d.last_id;
}

// ================= TESTING: COMPARE =================
// Rows = config versions (remote-control pushes) or builds. Deaths per minute gets a 95% range (Poisson); a row is
// "fewer/more deaths" than the baseline only when the gap is bigger than chance (|z| >= 1.96).
async function pCompare() {
  st.cmpBy = st.cmpBy || "cv";
  $("#top-tools").append(segEl([["cv", "By config version"], ["build", "By build"]], st.cmpBy, v => { st.cmpBy = v; st.cmpBase = null; loadCompare(); }, "Group by"));
  put($("#page"), html`<div class="stack"><div class="tiles" id="cmp-tiles"></div>
    <div class="card"><div class="card-h"><div><h2 id="cmp-h">Results</h2><p class="muted" id="cmp-sub"></p></div>
      <label class="check fine"><input type="checkbox" id="cmp-small" ${raw(st.cmpSmall ? "checked" : "")}> Show samples under 2 min</label></div>
      <div class="table-wrap" id="cmp-t"><p class="empty">Loading…</p></div></div>
    <p class="hint">Click a row to make it the baseline. The bar is deaths per minute: shaded = the 95% range, line = the value, dashed = the baseline.
      “Unclear” means the difference could still be chance; it needs more minutes. Fewer than 10 deaths or 5 minutes is marked as too little data.</p></div>`);
  $("#cmp-small").onchange = e => { st.cmpSmall = e.target.checked; drawCompare(); };
  $("#cmp-t").onclick = e => { const tr = e.target.closest("tr[data-key]"); if (tr) { st.cmpBase = tr.dataset.key; drawCompare(); } };
  await filterBar(loadCompare);
  loadCompare();
}
async function loadCompare() {
  try { st.C = await api("GET", "compare?" + tq(`&by=${st.cmpBy}`)); } catch (e) { return fail(e); }
  drawCompare();
}
function verdict(r, b) {
  if (r === b) return html`<span class="pill pill--acc">baseline</span>`;
  if (r.dpm == null || b.dpm == null || !b.dpm) return html`<span class="pill">–</span>`;
  const z = rateZ(r.deaths, r.min, b.deaths, b.min), d = Math.round((r.dpm / b.dpm - 1) * 100);
  const lab = `${d > 0 ? "+" : ""}${d}%`, tip = `z = ${z.toFixed(2)} (|z| ≥ 1.96 = not chance)`;
  if (r.noise || b.noise) return html`<span class="pill" title="${tip}">${lab} · too little data</span>`;
  if (Math.abs(z) < 1.96) return html`<span class="pill" title="${tip}">${lab} · unclear</span>`;
  return z < 0 ? html`<span class="pill pill--good" title="${tip}">${lab} · fewer deaths</span>` : html`<span class="pill pill--bad" title="${tip}">${lab} · more deaths</span>`;
}
function ciBar(r, max, base) {
  if (r.dpm == null) return html`<span class="muted">–</span>`;
  const sc = v => Math.min(100, Math.max(0, v / max * 100)).toFixed(1);
  return html`<span class="ci" aria-hidden="true"><i class="ci-r" data-l="${sc(r.lo)}" data-w="${(sc(r.hi) - sc(r.lo)).toFixed(1)}"></i>
    ${base && base.dpm != null ? html`<i class="ci-b" data-l="${sc(base.dpm)}"></i>` : ""}<i class="ci-d" data-l="${sc(r.dpm)}"></i></span>
    <b class="num">${f2(r.dpm)}</b><span class="sub num">${f2(r.lo)}–${f2(r.hi)}</span>`;
}
function drawCompare() {
  const C = st.C; if (!C || !$("#cmp-t")) return;
  const T = C.total || { min: 0, deaths: 0, kills: 0, sessions: 0 };
  put($("#cmp-tiles"), html`${[[mins(T.min), "alive"], [T.dpm != null ? f2(T.dpm) : "–", `deaths / min${T.lo != null ? ` (${f2(T.lo)}–${f2(T.hi)})` : ""}`],
    [kdOf(T), "K/D"], [pct(T.hit), "shots landed"], [pct(T.one_pct), "one-shot deaths"], [T.sessions || 0, "sessions"]]
    .map(([v, k]) => html`<div class="tile"><b>${v}</b><span>${k}</span></div>`)}`);
  let rows = C.rows.filter(r => st.cmpSmall || r.min >= 2);
  const legacy = C.by === "build" ? rows.filter(r => !String(r.key).startsWith("#")).length : 0;
  if (C.by === "build" && !st.cmpSmall && rows.some(r => String(r.key).startsWith("#"))) rows = rows.filter(r => String(r.key).startsWith("#"));
  $("#cmp-h").textContent = C.by === "cv" ? "By config version" : "By build";
  $("#cmp-sub").textContent = `${rows.length} of ${C.rows.length} rows${C.by === "build" && legacy && !st.cmpSmall ? ", builds from before numbering hidden" : ""} · ${C.accts.length ? C.accts.join(", ") : "everyone"}`;
  if (!rows.length) return put($("#cmp-t"), html`<p class="empty">No play data for these accounts in this range.</p>`);
  const base = rows.find(r => String(r.key) === String(st.cmpBase)) || rows.reduce((a, b) => (b.min > a.min ? b : a));
  const max = Math.max(0.5, ...rows.map(r => r.hi || r.dpm || 0)) * 1.05;
  const what = r => C.by === "cv"
    ? html`${r.note ? html`<b class="note">${r.note}</b>` : r.key === 0 ? html`<span class="muted">no remote config (players' own settings)</span>` : ""}
      ${Object.keys(r.applied || {}).length ? html`<div class="applied">${Object.entries(r.applied).map(([k, v]) => html`<code title="${KEYINFO[k] || k}">${k}=${String(v)}</code>`)}</div>` : ""}`
    : html`${r.ch ? html`<span class="pill ${r.ch === "beta" ? "pill--acc" : ""}">${r.ch}</span> ` : ""}${r.note ? html`<b class="note">${r.note}</b>` : ""}
      <span class="sub">${r.ver ? r.ver + " · " : ""}${r.ts ? "deployed " + when(r.ts) : ""}</span>`;
  put($("#cmp-t"), html`<table class="cmp"><thead><tr><th>${C.by === "cv" ? "Config" : "Build"}</th><th>What it is</th><th class="r">Alive</th><th class="r">Deaths</th>
    <th>Deaths / min</th><th>vs baseline</th><th class="r">K/D</th><th class="r">Hit</th><th class="r">One-shot</th><th>Who</th></tr></thead>
    <tbody>${rows.map(r => html`<tr class="click ${r === base ? "base" : ""}" data-key="${r.key}" tabindex="0" title="Make this the baseline">
      <td><b>${r.label}</b><span class="sub">${r.sessions} session${r.sessions === 1 ? "" : "s"}</span></td><td class="what">${what(r)}</td>
      <td class="r num">${mins(r.min)}</td><td class="r num">${r.deaths}</td><td class="cell-ci">${ciBar(r, max, base)}</td><td>${verdict(r, base)}</td>
      <td class="r num">${r.kd == null ? kdOf(r) : f2(r.kd)}</td><td class="r num">${pct(r.hit)}</td><td class="r num">${pct(r.one_pct)}</td>
      <td class="fine">${r.accts.join(", ")}<span class="sub">${day(r.a)} ${hm(r.a)}–${day(r.b) !== day(r.a) ? day(r.b) + " " : ""}${hm(r.b)}</span></td></tr>`)}</tbody></table>`);
}

// ================= TESTING: BUILDS =================
async function pBuilds() {
  put($("#page"), html`<div class="stack"><div class="grid grid--even" id="bd-ch"><div class="card"><p class="empty">Loading…</p></div></div>
    <div class="card"><div class="card-h"><div><h2>Script errors</h2><p class="muted">Caught errors from every player's game, grouped by message. Sent by builds with error reporting only.</p></div></div><div class="table-wrap" id="bd-err"></div></div>
    <div class="card"><div class="card-h"><div><h2>Build health</h2><p class="muted">Every player who ran the build in this range.</p></div>
      <label class="check fine"><input type="checkbox" id="bd-old" ${raw(st.bdOld ? "checked" : "")}> Show builds from before numbering</label></div><div class="table-wrap" id="bd-t"></div></div>
    <div class="card"><div class="card-h"><h2>Build history</h2></div><div class="table-wrap" id="rl-t"></div></div>
    <div class="grid grid--even"><div class="card"><div class="card-h"><h2>Loader line</h2><button class="btn btn--sm" type="button" id="sc-copy">Copy</button></div>
      <div class="card-b stack"><code class="mono" id="sc-line"></code><p class="hint">Players paste this once. The loader holds no secrets: without a valid key it downloads nothing.</p></div></div>
    <div class="card"><div class="card-h"><h2>Files</h2></div><div class="card-b stack"><div class="toolbar"><a class="btn btn--sm" href="/admin/api/download?f=script&amp;ch=stable">Download stable (owner copy)</a>
      <a class="btn btn--sm" href="/admin/api/download?f=script&amp;ch=beta">Download beta</a><a class="btn btn--sm" href="/admin/api/download?f=loader">Download loader.lua</a></div>
      <p class="hint">Deploy a beta with <code>scripts/deploy.sh --beta --note "…"</code>. Players switch on their next loader start; their script prints [UPDATE] within a minute.</p></div></div></div></div>`);
  $("#bd-old").onchange = e => { st.bdOld = e.target.checked; drawBuilds(); };
  await filterBar(loadBuilds, { noAccts: true, noSrv: true, note: "all players" });
  loadBuilds();
}
async function loadBuilds() {
  try { [st.H, st.SC] = await Promise.all([api("GET", `health?since=${TF.since}`), api("GET", "script")]); } catch (e) { return fail(e); }
  drawBuilds();
}
function healthOf(rec) { const k = rec ? (rec.build ? "#" + rec.build : rec.ver) : null; return k ? (st.H.builds || []).find(b => b.key === k) : null; }
function metrics(h) {
  if (!h) return html`<p class="hint">Nobody ran it in this range.</p>`;
  const stops = h.stops.reduce((a, s) => a + s.n, 0);
  return html`<div class="metrics">${[[h.accts.length, "players"], [mins(h.min), "alive"], [h.loads || "–", "loads"], [h.avg_session != null ? mins(h.avg_session) : "–", "per session"],
    [h.errors ? `${h.errors}${h.err_per_h != null ? ` (${h.err_per_h}/h)` : ""}` : "0", "errors", h.errors ? "bad" : ""], [stops || "0", "stops", stops ? "warn" : ""],
    [f2(h.dpm), "deaths / min"], [h.kd == null ? kdOf(h) : f2(h.kd), "K/D"]].map(([v, k, c]) => html`<div class="${c || ""}"><b>${v}</b><span>${k}</span></div>`)}</div>
    ${h.stops.length ? html`<p class="fine muted">Stopped: ${h.stops.map(s => `${s.why} (${s.n})`).join(" · ")}</p>` : ""}`;
}
function drawBuilds() {
  const H = st.H, S = st.SC; if (!H || !S || !$("#bd-ch")) return;
  const R = S.releases || { stable: null, beta: null, beta_members: [], history: [] };
  const sameBeta = !R.beta || (R.stable && R.beta.ver === R.stable.ver);
  const others = (S.accounts || []).filter(a => !R.beta_members.includes(a));
  const dis = c => raw(c ? "disabled" : "");
  // before the first stable publish, stable = the original single file (no build number)
  const stableRec = R.stable || (S.ver ? { build: 0, ver: S.ver, ts: null, note: "original file, no numbered build yet" } : null);
  const head = (rec, ch) => rec ? html`<div class="big">${rec.build ? "#" + rec.build : "build 0"}</div><p class="fine muted"><span class="mono">${rec.ver}</span>${rec.ts ? " · " + when(rec.moved || rec.ts) : ""}${rec.git ? " · git " + rec.git : ""}</p>${rec.note ? html`<p class="note">${rec.note}</p>` : ""}`
    : html`<p class="muted">${ch === "beta" ? "No beta running: testers get stable." : "none"}</p>`;
  put($("#bd-ch"), html`<div class="card"><div class="card-h"><h2><span class="pill pill--good">stable</span> Everyone</h2></div>
      <div class="card-b stack">${head(stableRec, "stable")}${metrics(healthOf(stableRec))}</div></div>
    <div class="card"><div class="card-h"><h2><span class="pill pill--acc">beta</span> Testers</h2><div class="toolbar">
      <button class="btn btn--primary btn--sm" type="button" id="rl-promote" ${dis(sameBeta)}>Promote to stable</button><button class="btn btn--sm" type="button" id="rl-end" ${dis(sameBeta)}>End beta</button></div></div>
      <div class="card-b stack">${sameBeta ? html`<p class="muted">Same as stable.</p>` : html`${head(R.beta, "beta")}${metrics(healthOf(R.beta))}`}
      <div class="toolbar"><span class="fb-l">Testers</span>${R.beta_members.length ? R.beta_members.map(m => html`<button class="chip" type="button" data-rm="${m}" title="Back to stable"><span class="dot ${onlineOf(m) ? "dot--on" : ""}"></span>${m}<b aria-hidden="true">×</b></button>`) : html`<span class="muted fine">nobody yet</span>`}
        <select class="inp inp--sm" id="bm-add" aria-label="Add a tester" ${dis(!others.length)}><option value="">+ add tester</option>${others.map(a => html`<option value="${a}">${a}</option>`)}</select></div></div></div>`);
  const rel = async (body, msg) => { try { await api("POST", "releases", body); toast(msg); loadBuilds(); } catch (x) { fail(x); } };
  const mem = async (name, on) => { try { await api("POST", "licenses", { op: on ? "beta_on" : "beta_off", name }); toast(`${name}: ${on ? "in the beta" : "back on stable"}`); st.roster = null; loadBuilds(); } catch (x) { fail(x); } };
  $("#rl-promote").onclick = async () => { if (await confirmBox(`Promote beta #${R.beta.build} to stable?`, "Everyone gets this build on their next loader start.", "Promote", false)) rel({ op: "promote" }, `Stable is now #${R.beta.build}`); };
  $("#rl-end").onclick = async () => { if (await confirmBox("End the beta?", "Testers go back to the stable build on their next loader start.", "End beta", true)) rel({ op: "end_beta" }, "Beta ended"); };
  $("#bd-ch").onclick = e => { const b = e.target.closest("[data-rm]"); if (b) mem(b.dataset.rm, false); };
  $("#bm-add").onchange = e => { if (e.target.value) mem(e.target.value, true); };

  // errors
  put($("#bd-err"), H.errors.length ? html`<table><thead><tr><th>Last seen</th><th>Where</th><th>Error</th><th class="r">Count</th><th>Builds</th><th>Players</th></tr></thead><tbody>${H.errors.map(e =>
    html`<tr><td class="num nowrap">${ago(e.last)}<span class="sub">first ${when(e.first)}</span></td><td><code>${e.where}</code></td><td class="err-msg"><code>${e.msg}</code></td>
      <td class="r num"><b>${e.n}</b></td><td class="fine">${e.builds.join(", ")}</td><td class="fine">${e.accts.join(", ")}</td></tr>`)}</tbody></table>`
    : html`<p class="empty">No errors reported in this range.</p>`);

  // health table
  const numbered = H.builds.filter(b => String(b.key).startsWith("#"));
  const rows = st.bdOld || !numbered.length ? H.builds : numbered;
  const tag = k => [stableRec && (k === "#" + stableRec.build || k === stableRec.ver) ? html`<span class="pill pill--good">stable</span> ` : "", !sameBeta && R.beta && "#" + R.beta.build === k ? html`<span class="pill pill--acc">beta</span>` : ""];
  put($("#bd-t"), rows.length ? html`<table><thead><tr><th>Build</th><th>Note</th><th class="r">Players</th><th class="r">Sessions</th><th class="r">Alive</th><th class="r">Loads</th>
    <th class="r">Errors</th><th>Stops</th><th class="r">Deaths / min</th><th class="r">K/D</th><th class="r">Hit</th></tr></thead><tbody>${rows.map(b =>
    html`<tr><td class="nowrap"><b>${b.key}</b> ${tag(b.key)}<span class="sub">${b.ts ? when(b.ts) : b.a ? "seen " + day(b.a) : ""}</span></td><td class="fine">${b.note || ""}</td>
      <td class="r num">${b.accts.length}</td><td class="r num">${b.sessions}</td><td class="r num">${mins(b.min)}</td><td class="r num">${b.loads || "–"}</td>
      <td class="r num ${b.errors ? "t-bad" : ""}">${b.errors || "–"}${b.err_per_h ? html`<span class="sub">${b.err_per_h}/h</span>` : ""}</td>
      <td class="fine">${b.stops.map(s => `${s.why} (${s.n})`).join(", ") || "–"}</td><td class="r num">${f2(b.dpm)}</td><td class="r num">${b.kd == null ? kdOf(b) : f2(b.kd)}</td><td class="r num">${pct(b.hit)}</td></tr>`)}</tbody></table>`
    : html`<p class="empty">Nobody played in this range.</p>`);

  // history + loader
  const htag = h => [R.stable && R.stable.build === h.build ? html`<span class="pill pill--good">stable</span> ` : "", !sameBeta && R.beta && R.beta.build === h.build ? html`<span class="pill pill--acc">beta</span>` : ""];
  put($("#rl-t"), R.history.length ? html`<table><thead><tr><th>Build</th><th>Version</th><th>Deployed</th><th>As</th><th>Note</th><th>Live on</th><th></th></tr></thead><tbody>${R.history.map(h =>
    html`<tr><td><b>#${h.build}</b></td><td class="mono">${h.ver}${h.git ? html`<span class="sub">git ${h.git}</span>` : ""}</td><td class="num">${when(h.ts)}</td><td>${h.ch}</td><td class="fine">${h.note || ""}</td><td>${htag(h)}</td>
      <td class="r nowrap"><button class="btn btn--ghost btn--sm" type="button" data-pt="stable" data-b="${h.build}">Make stable</button> <button class="btn btn--ghost btn--sm" type="button" data-pt="beta" data-b="${h.build}">Make beta</button></td></tr>`)}</tbody></table>`
    : html`<p class="empty">No builds yet. The first deploy creates build #1.</p>`);
  $("#rl-t").onclick = async e => { const b = e.target.closest("[data-pt]"); if (!b) return; const ch = b.dataset.pt, n = +b.dataset.b;
    if (await confirmBox(`Point ${ch} at build #${n}?`, ch === "stable" ? "Everyone gets this build on their next loader start." : "Testers get this build on their next loader start.", "Switch", ch === "stable")) rel({ op: "point", channel: ch, build: n }, `${ch} is now #${n}`); };
  const line = `loadstring(game:HttpGet("${S.base}/loader.lua"))()`;
  $("#sc-line").textContent = line; $("#sc-copy").onclick = () => copy(line, "Loader line copied");
}

// ================= TESTING: SESSIONS =================
async function pSessions() {
  put($("#page"), html`<div class="stack"><div class="card"><div class="card-h"><h2>Sessions</h2><span class="muted fine" id="ss-n"></span></div><div class="table-wrap" id="ss-t"><p class="empty">Loading…</p></div></div>
    <div class="card"><div class="card-h"><h2>Export data</h2></div><div class="card-b stack"><p class="hint" id="x-hint"></p>
      <div class="toolbar"><select class="inp" id="x-kind" aria-label="Data">${["deaths", "hits", "shots", "intel", "state", "ctrl", "uploads", "all"].map(k => html`<option>${k}</option>`)}</select>
      <select class="inp" id="x-since" aria-label="Range"><option value="">All time</option><option value="2h">Last 2 h</option><option value="24h">Last 24 h</option><option value="7d">Last 7 days</option></select>
      <select class="inp" id="x-fmt" aria-label="Format"><option>csv</option><option>jsonl</option></select><button class="btn btn--primary btn--sm" type="button" id="x-go">Download</button></div></div></div></div>`);
  const xacct = () => testAccts().length === 1 ? testAccts()[0] : "";
  $("#x-go").onclick = () => { location.href = `/admin/api/export?kind=${encodeURIComponent($("#x-kind").value)}&format=${encodeURIComponent($("#x-fmt").value)}&since=${encodeURIComponent($("#x-since").value)}&acct=${encodeURIComponent(xacct())}`; };
  $("#ss-t").onclick = e => { const tr = e.target.closest("tr[data-s]"); if (tr) go(`t/session/${encodeURIComponent(tr.dataset.s)}`); };
  $("#ss-t").onkeydown = e => { const tr = e.target.closest("tr[data-s]"); if (tr && e.key === "Enter") go(`t/session/${encodeURIComponent(tr.dataset.s)}`); };
  const load = async () => {
    $("#x-hint").textContent = `CSV or JSON lines for ${xacct() || "everyone (pick exactly one account above to export only theirs)"}. Nested fields become a.b columns.`;
    let r; try { r = await api("GET", "sessions?" + tq()); } catch (e) { return fail(e); }
    $("#ss-n").textContent = `${r.sessions.length} sessions`;
    put($("#ss-t"), r.sessions.length ? html`<table><thead><tr><th>When</th><th>Account</th><th>Build</th><th>Configs</th><th>Server</th><th class="r">Alive</th><th class="r">Deaths</th><th class="r">Kills</th>
      <th class="r">K/D</th><th class="r">Deaths / min</th><th class="r">Hit</th></tr></thead><tbody>${r.sessions.map(s =>
      html`<tr class="click" data-s="${s.session}" tabindex="0"><td class="num nowrap">${day(s.a)} ${hm(s.a)}–${hm(s.b)}</td><td>${s.acct}</td>
        <td class="nowrap">${s.build}${s.ch === "beta" ? html` <span class="pill pill--acc">beta</span>` : ""}</td><td class="fine">${s.cvs.map(v => "v" + v).join(", ")}</td>
        <td class="fine">${s.srv.filter(x => x !== "unknown").join(", ") || "–"}</td><td class="r num">${mins(s.min)}</td><td class="r num">${s.deaths}</td><td class="r num">${s.kills}</td>
        <td class="r num">${s.kd == null ? kdOf(s) : f2(s.kd)}</td><td class="r num">${f2(s.dpm)}</td><td class="r num">${pct(s.hit)}</td></tr>`)}</tbody></table>`
      : html`<p class="empty">No sessions for these accounts in this range.</p>`);
  };
  await filterBar(load, { noSrv: true });
  load();
}

// ================= TESTING: ONE SESSION =================
async function pSession() {
  const sid = st.arg;
  const back = document.createElement("a"); back.className = "btn btn--sm"; back.href = "#t/sessions"; back.textContent = "All sessions";
  $("#top-tools").append(back);
  put($("#page"), html`<div class="stack"><div class="tiles" id="sx-tiles"></div><div class="grid grid--even">
    <div class="card"><div class="card-h"><h2>Deaths by ticks since our flip</h2></div><div class="card-b bars" id="b-flip"></div></div>
    <div class="card"><div class="card-h"><h2>Likely killers</h2></div><div class="card-b bars" id="b-killer"></div></div>
    <div class="card"><div class="card-h"><h2>Deaths by my state</h2></div><div class="card-b bars" id="b-state"></div></div>
    <div class="card"><div class="card-h"><h2>Killer weapon</h2></div><div class="card-b bars" id="b-killer_wep"></div></div>
    <div class="card"><div class="card-h"><h2>Deaths by my weapon</h2></div><div class="card-b bars" id="b-weapon"></div></div>
    <div class="card"><div class="card-h"><h2>My misses</h2><p class="muted">not counting deaths</p></div><div class="card-b bars" id="b-miss"></div></div></div>
    <div class="grid grid--even"><div class="card"><div class="card-h"><h2>By config version</h2></div><div class="card-b card-b--flush table-wrap" id="sx-cv"></div></div>
      <div class="card"><div class="card-h"><h2>Last deaths</h2></div><div class="card-b card-b--flush" id="sx-d"></div></div></div>
    <div class="card"><div class="card-h"><h2>Full report</h2><div class="toolbar"><select class="inp" id="r-since" aria-label="Range"><option value="">Whole session</option><option value="10m">Last 10 min</option><option value="30m">Last 30 min</option></select>
      <button class="btn btn--sm" type="button" id="r-go">Run</button></div></div><div class="card-b"><pre class="report muted" id="r-out">Press Run for the full text report of this session.</pre></div></div>
    <p class="hint">“Likely killer” is a guess (the only scoped enemy, else the nearest): the game has no attacker event. Small samples are noise.</p></div>`);
  $("#r-go").onclick = async () => {
    $("#r-out").textContent = "Running…";
    try { $("#r-out").textContent = await api("GET", `report?session=${encodeURIComponent(sid)}&since=${$("#r-since").value}&acct=`); $("#r-out").classList.remove("muted"); }
    catch (e) { fail(e); }
  };
  let S; try { S = await api("GET", `status?session=${encodeURIComponent(sid)}&acct=`); } catch (e) { return fail(e); }
  const s = S.sessions.find(x => x.session === sid);
  $("#page-sub").textContent = s ? `${s.acct} · ${when(s.a)}–${hm(s.b)} · build ${S.state.ver || "?"}` : `${sid} · build ${S.state.ver || "?"}`;
  put($("#sx-tiles"), tilesFor(S.totals));
  for (const k of ["flip", "state", "weapon", "killer", "killer_wep", "miss"]) {
    const list = S.dist[k] || [], max = Math.max(1, ...list.map(x => x[1]));
    put($("#b-" + k), list.length ? html`${list.map(([lab, n]) => html`<div class="bar"><span class="lab" title="${lab}">${lab}</span><i data-w="${Math.max(3, n / max * 100)}"></i><span class="n">${n}</span></div>`)}`
      : html`<p class="hint">No data.</p>`);
  }
  put($("#sx-cv"), S.by_cv.length ? html`<table><thead><tr><th>Config</th><th class="r">Alive</th><th class="r">Deaths</th><th class="r">Kills</th><th class="r">Deaths / min</th><th>Note</th></tr></thead><tbody>${[...S.by_cv].reverse().map(c =>
    html`<tr><td>v${c.v}</td><td class="r num">${mins(c.min)}</td><td class="r num">${c.deaths}</td><td class="r num">${c.kills}</td><td class="r num">${c.dpm ?? "–"}</td><td class="fine">${c.note || ""}</td></tr>`)}</tbody></table>`
    : html`<p class="empty">No data.</p>`);
  put($("#sx-d"), S.recent_deaths.length ? html`<table><tbody>${S.recent_deaths.map(d => html`<tr><td class="muted num">${hm(d.ts)}</td><td>${d.state || "?"} ${d.side || ""}<span class="sub">flip ${d.flip ?? "?"}t · v${d.cv ?? 0}</span></td>
    <td>${d.killer || "?"}<span class="sub">${[d.kwep, d.kdist != null ? d.kdist + " st" : ""].filter(Boolean).join(" · ")}</span></td></tr>`)}</tbody></table>`
    : html`<p class="empty">No deaths in this session.</p>`);
}

// ================= PLAYERS: ROSTER =================
// Every license key plus every account seen in the data (owner = the master token). Online = a state snapshot in
// the last 20 s. Range stats are over the picked range; "now" is their current game session.
const licState = k => k.state === "active" ? "active" : String(k.state).includes("expired") ? "expired" : "revoked";
const pState = p => !p.lic ? "nokey" : licState(p.lic);
const ending = p => p.lic && pState(p) === "active" && p.lic.expires && p.lic.expires - now() < 3 * 86400;
const licObj = p => ({ name: p.acct, beta: p.beta, uid: p.lic?.uid, user: p.user, state: p.lic?.state || "active", note: p.lic?.note });
function licPill(p) {
  const s = pState(p);
  if (s === "nokey") return html`<span class="pill" title="${p.acct === "owner" ? "The master token" : "No license key with this name"}">${p.acct === "owner" ? "master token" : "no key"}</span>`;
  return html`<span class="pill ${s === "active" ? (ending(p) ? "pill--warn" : "pill--good") : "pill--bad"}">${s}</span>`;
}
async function pPlayers() {
  st.pRange = st.pRange || "7d"; st.plFilter = st.plFilter || "all"; st.plQ = st.plQ || "";
  const add = document.createElement("button"); add.className = "btn btn--primary"; add.type = "button"; add.textContent = "New key"; add.onclick = newKey;
  $("#top-tools").append(selEl(RANGES, st.pRange, v => { st.pRange = v; loadPlayers(); }, "Range for the stats"), add);
  put($("#page"), html`<div class="stack"><div class="tiles" id="pl-tiles"></div><div class="card"><div class="card-h"><div class="seg" id="pl-f" role="group" aria-label="Filter"></div>
    <input class="inp search" id="pl-q" type="search" placeholder="Search name, Roblox user or note" value="${st.plQ}"></div><div class="table-wrap" id="pl-t"><p class="empty">Loading…</p></div></div>
    <p class="hint">Click a player for their profile: stats, sessions, configs, downloads and every license action. A key locks to the first Roblox account that logs in
      and works on one device at a time; revoking, ending the session or unbinding stops their script within about a minute.</p></div>`);
  $("#pl-q").oninput = e => { st.plQ = e.target.value; drawPlayers(); };
  $("#pl-f").onclick = e => { const b = e.target.closest("button[data-f]"); if (b) { st.plFilter = b.dataset.f; drawPlayers(); } };
  $("#pl-t").onclick = e => {
    const m = e.target.closest("[data-menu]"); if (m) { e.stopPropagation(); const p = st.roster.find(x => x.acct === m.dataset.menu); return licMenu(m, licObj(p)); }
    if (e.target.closest(".menu-pop")) return;
    const tr = e.target.closest("tr[data-a]"); if (tr) go(`p/player/${encodeURIComponent(tr.dataset.a)}`);
  };
  $("#pl-t").onkeydown = e => { const tr = e.target.closest("tr[data-a]"); if (tr && e.key === "Enter" && e.target === tr) go(`p/player/${encodeURIComponent(tr.dataset.a)}`); };
  await loadPlayers();
}
async function loadPlayers() {
  try { st.roster = (await api("GET", `players?since=${st.pRange || "7d"}`)).players; } catch (e) { return fail(e); }
  drawPlayers();
}
function drawPlayers() {
  if (!$("#pl-t")) return;
  const P = st.roster || [];
  const c = { all: P.length, online: P.filter(p => p.online).length, active: P.filter(p => pState(p) === "active").length,
    ending: P.filter(ending).length, ended: P.filter(p => ["expired", "revoked"].includes(pState(p))).length, nokey: P.filter(p => pState(p) === "nokey").length };
  const played = P.filter(p => p.stats && p.stats.min > 0).length;
  put($("#pl-tiles"), html`${[[c.online, "in game now"], [played, `played (${RANGES.find(r => r[0] === st.pRange)[1].toLowerCase()})`], [c.active, "active keys"],
    [c.ending, "end within 3 days"], [c.ended, "expired or revoked"]].map(([v, k]) => html`<div class="tile"><b>${v}</b><span>${k}</span></div>`)}`);
  const F = [["all", "All"], ["online", "In game"], ["active", "Active"], ["ending", "Ending soon"], ["ended", "Expired or revoked"], ["nokey", "No key"]];
  put($("#pl-f"), html`${F.filter(([f]) => f === "all" || c[f]).map(([f, l]) => html`<button type="button" data-f="${f}" aria-pressed="${st.plFilter === f}">${l} <span class="count">${c[f]}</span></button>`)}`);
  const q = st.plQ.trim().toLowerCase();
  const keep = p => ({ all: true, online: p.online, active: pState(p) === "active", ending: ending(p), ended: ["expired", "revoked"].includes(pState(p)), nokey: pState(p) === "nokey" })[st.plFilter];
  const rows = P.filter(p => keep(p) && (!q || [p.acct, p.user, p.lic?.note].some(x => String(x || "").toLowerCase().includes(q))));
  const nowCell = p => {
    const s = p.snap;
    if (p.online && s) return html`<span class="pill pill--good"><span class="dot dot--on"></span>in game</span> <span class="fine">${bKey(s.build, s.ch) || s.ver || ""}</span>
      <span class="sub">${[s.srv, s.my_state, s.hp != null ? "hp " + s.hp : "", s.wep].filter(Boolean).join(" · ")}${p.cur ? ` · this game ${p.cur.kills}/${p.cur.deaths} in ${mins(p.cur.min)}` : ""}</span>`;
    return html`<span class="muted">${p.last ? ago(p.last) : "never played"}</span><span class="sub">${s ? (bKey(s.build, s.ch) || s.ver || "") : ""}</span>`;
  };
  put($("#pl-t"), rows.length ? html`<table class="roster"><thead><tr><th>Player</th><th>License</th><th>Now</th><th class="r">Played</th><th class="r">K/D</th><th class="r">Deaths / min</th><th class="r">Hit</th><th></th></tr></thead>
    <tbody>${rows.map(p => { const x = p.stats; return html`<tr class="click" data-a="${p.acct}" tabindex="0">
      <td><b>${p.acct}</b>${p.beta ? html` <span class="pill pill--acc">beta</span>` : ""}<span class="sub">${p.user || ""}</span></td>
      <td>${licPill(p)}<span class="sub">${p.lic ? left(p.lic.expires) : ""}</span></td><td>${nowCell(p)}</td>
      <td class="r num">${x ? mins(x.min) : "–"}<span class="sub">${x ? `${x.sessions} session${x.sessions === 1 ? "" : "s"}` : ""}</span></td>
      <td class="r num">${x ? (x.kd == null ? kdOf(x) : f2(x.kd)) : "–"}<span class="sub">${x ? `${x.kills}/${x.deaths}` : ""}</span></td>
      <td class="r num">${x ? f2(x.dpm) : "–"}</td><td class="r num">${x ? pct(x.hit) : "–"}</td>
      <td class="r">${p.lic ? html`<div class="menu"><button class="btn btn--ghost btn--sm" type="button" data-menu="${p.acct}" aria-haspopup="true" aria-label="Actions for ${p.acct}">•••</button></div>` : ""}</td></tr>`; })}</tbody></table>`
    : html`<p class="empty">${P.length ? "Nobody matches." : "No players yet. Make the first key with New key."}</p>`);
}

// ================= LICENSE ACTIONS (roster menu + profile buttons) =================
async function licAct(k, op, days) {
  const run = async (body, msg) => { try { await api("POST", "licenses", { name: k.name, ...body }); toast(msg); st.roster = null; route(); } catch (x) { fail(x); } };
  if (op === "beta_on" || op === "beta_off") return run({ op }, `${k.name}: ${op === "beta_on" ? "in the beta (gets the beta build on the next loader start)" : "back on stable"}`);
  if (op === "add_days") return run({ op, days }, `${k.name}: +${days} days`);
  if (op === "set") return dialog(html`<form><div class="dlg-h"><h2>Set expiry for ${k.name}</h2><p>Days from now. 0 means it never expires.</p></div>
    <div class="dlg-b"><label class="field"><span>Days</span><input name="d" type="number" min="0" max="3650" step="1" value="30" required></label></div>
    <div class="dlg-f"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn--primary" type="submit">Save</button></div></form>`,
    async (f, dd) => { dd.close(); await run({ op: "extend", days: +f.get("d") }, `${k.name}: ${+f.get("d") ? f.get("d") + " days from now" : "never expires"}`); });
  if (op === "note") return dialog(html`<form><div class="dlg-h"><h2>Note for ${k.name}</h2></div><div class="dlg-b"><label class="field"><span>Note</span><input name="n" maxlength="120" value="${k.note || ""}"></label></div>
    <div class="dlg-f"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn--primary" type="submit">Save</button></div></form>`,
    async (f, dd) => { dd.close(); await run({ op: "note", note: f.get("n") }, "Note saved"); });
  const ask = {
    kick: [`End ${k.name}'s session?`, "Their script stops within about a minute. They can log in again right away.", "End session", false],
    reset: [`Unbind ${k.name} from ${k.user || "their account"}?`, "The key locks to whichever Roblox account logs in next. Their current session ends.", "Unbind", true],
    revoke: [`Revoke ${k.name}?`, "The key stops working and their script stops within about a minute. You can enable it again later.", "Revoke", true],
    enable: [`Enable ${k.name} again?`, "The key works again until its expiry.", "Enable", false],
    delete: [`Delete ${k.name}?`, "The key is gone for good and cannot be brought back. Their play data stays.", "Delete", true],
  }[op];
  if (ask && await confirmBox(...ask)) {
    await run({ op }, `${k.name}: ${ask[2].toLowerCase()} done`);
    if (op === "delete" && st.page === "player") go("p/players");
  }
}
function licMenu(btn, k) {
  $$(".menu-pop").forEach(m => m.remove());
  const pop = document.createElement("div"); pop.className = "menu-pop"; pop.setAttribute("role", "menu");
  const act = licState(k) === "revoked" ? ["enable", "Enable key"] : ["revoke", "Revoke key"];
  put(pop, html`<button type="button" data-op="add_days" data-d="7">Add 7 days</button><button type="button" data-op="add_days" data-d="30">Add 30 days</button>
    <button type="button" data-op="set">Set expiry…</button><button type="button" data-op="note">Edit note…</button>
    <button type="button" data-op="${k.beta ? "beta_off" : "beta_on"}">${k.beta ? "Remove from beta" : "Add to beta"}</button><hr>
    <button type="button" data-op="kick">End live session</button><button type="button" data-op="reset" ${raw(k.uid ? "" : "disabled")}>Unbind Roblox account</button>
    <button type="button" data-op="${act[0]}" class="${act[0] === "revoke" ? "bad" : ""}">${act[1]}</button><button type="button" data-op="delete" class="bad">Delete key</button>`);
  btn.parentElement.append(pop); $("button", pop).focus();
  const close = ev => { if (!pop.contains(ev.target)) { pop.remove(); document.removeEventListener("pointerdown", close, true); } };
  setTimeout(() => document.addEventListener("pointerdown", close, true));
  pop.onkeydown = e => { if (e.key === "Escape") { pop.remove(); btn.focus(); } };
  pop.onclick = e => { e.stopPropagation(); const b = e.target.closest("button[data-op]"); if (!b) return; pop.remove(); licAct(k, b.dataset.op, +b.dataset.d || 0); };
}
function newKey() {
  dialog(html`<form><div class="dlg-h"><h2>New license key</h2><p>The key is shown once. Only its hash is stored.</p></div>
    <div class="dlg-b"><label class="field"><span>Name (who it is for)</span><input name="name" maxlength="32" pattern="[A-Za-z0-9_.@-]{1,32}" placeholder="e.g. friend_ana" required></label>
    <label class="field"><span>Valid for</span><select name="days"><option value="7">7 days</option><option value="30" selected>30 days</option><option value="90">90 days</option><option value="365">1 year</option><option value="0">Never expires</option></select></label>
    <label class="field"><span>Note (admin only)</span><input name="note" maxlength="120" placeholder="optional"></label></div>
    <div class="dlg-f"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn--primary" type="submit">Create key</button></div></form>`,
    async (f, d) => {
      const r = await api("POST", "licenses", { op: "add", name: f.get("name").trim(), days: +f.get("days"), note: f.get("note") });
      put(d, html`<div class="dlg-h"><h2>Key for ${r.name}</h2><p>Copy it now. It will not be shown again.</p></div>
        <div class="dlg-b"><div class="secret"><code>${r.key}</code><button class="btn btn--sm" type="button" id="k-copy">Copy key</button></div>
        <label class="field"><span>Message to send them</span><textarea class="inp" readonly>${r.invite}</textarea></label></div>
        <div class="dlg-f"><button class="btn" type="button" id="k-inv">Copy message</button><button class="btn btn--primary" type="button" data-close>Done</button></div>`);
      $("#k-copy").onclick = () => copy(r.key, "Key copied"); $("#k-inv").onclick = () => copy(r.invite, "Message copied");
      d.addEventListener("close", () => { put(d, html``); st.roster = null; if (st.page === "players") loadPlayers(); }, { once: true });
    });
}

// ================= PLAYERS: ONE PLAYER =================
async function pPlayer() {
  const name = st.arg; st.ppRange = st.ppRange || "30d";
  const back = document.createElement("a"); back.className = "btn btn--sm"; back.href = "#p/players"; back.textContent = "All players";
  $("#top-tools").append(back, selEl(RANGES, st.ppRange, v => { st.ppRange = v; route(); }, "Range"));
  put($("#page"), html`<div class="stack" id="pp"><p class="empty">Loading…</p></div>`);
  let P; try { P = await api("GET", `player?name=${encodeURIComponent(name)}&since=${st.ppRange}`); } catch (e) { return fail(e); }
  const k = P.lic, s = P.snap, T = P.total, online = s && s.online;
  const pseudo = { acct: name, lic: k, beta: P.beta, user: P.user };
  $("#page-sub").textContent = [P.user ? `Roblox ${P.user}` : "", k?.uid ? `id ${k.uid}` : "", P.last ? `last seen ${ago(P.last)}` : "never played"].filter(Boolean).join(" · ");
  const actions = k ? html`<div class="toolbar">
      <button class="btn btn--sm" type="button" data-op="add_days" data-d="7">+7 days</button><button class="btn btn--sm" type="button" data-op="add_days" data-d="30">+30 days</button>
      <button class="btn btn--sm" type="button" data-op="set">Set expiry…</button><button class="btn btn--sm" type="button" data-op="note">Note…</button>
      <button class="btn btn--sm" type="button" data-op="${P.beta ? "beta_off" : "beta_on"}">${P.beta ? "Remove from beta" : "Add to beta"}</button></div>
    <div class="toolbar"><button class="btn btn--sm" type="button" data-op="kick">End session</button><button class="btn btn--sm" type="button" data-op="reset" ${raw(k.uid ? "" : "disabled")}>Unbind Roblox</button>
      <button class="btn btn--sm ${licState(k) === "revoked" ? "" : "btn--danger"}" type="button" data-op="${licState(k) === "revoked" ? "enable" : "revoke"}">${licState(k) === "revoked" ? "Enable key" : "Revoke key"}</button>
      <button class="btn btn--sm btn--danger" type="button" data-op="delete">Delete key</button></div>`
    : html`<p class="hint">${name === "owner" ? "The master token: no license to manage." : "No license key has this name (an old or deleted key)."}</p>`;
  const kv = (rows) => html`<dl class="kv">${rows.filter(r => r[1] != null && r[1] !== "").map(([a, b]) => html`<dt>${a}</dt><dd>${b}</dd>`)}</dl>`;
  const maxMin = Math.max(1, ...P.days.map(d => d.min));
  const tbl = (head, rows, empty) => rows.length ? html`<table><thead><tr>${head.map(h => html`<th class="${h.startsWith(">") ? "r" : ""}">${h.replace(/^>/, "")}</th>`)}</tr></thead><tbody>${rows}</tbody></table>` : html`<p class="empty">${empty}</p>`;
  put($("#pp"), html`
    <div class="card phead"><div><h2><span class="dot ${online ? "dot--on" : ""}"></span>${name}</h2>
      <div class="meta">${licPill(pseudo)}${P.beta ? html`<span class="pill pill--acc">beta tester</span>` : ""}${online ? html`<span class="pill pill--good">in game</span>` : ""}
        ${k ? html`<span class="fine muted">${left(k.expires)}${k.expires ? ` (${day(k.expires)})` : ""} · ${k.logins} logins · key made ${day(k.created)}${k.note ? " · " + k.note : ""}</span>` : ""}</div></div>
      <div class="stack stack--tight" id="pp-act">${actions}</div></div>
    ${online ? html`<div class="card"><div class="card-h"><h2>In game now</h2><button class="btn btn--sm btn--primary" type="button" id="pp-live">Watch live</button></div><div class="card-b">${kv([
      ["build", `${bKey(s.build, s.ch) || ""} ${s.ver || ""}`], ["server", `${s.srv || "?"} · job ${s.job || "?"}`], ["state", [s.my_state, s.hp != null ? "hp " + s.hp : ""].filter(Boolean).join(" · ")],
      ["weapon", s.wep], ["remote", s.remote ? `on · config v${s.cv || 0}` : "off"], ["snapshot", ago(s.ts)]])}</div></div>` : ""}
    <div class="tiles">${(T ? [[mins(T.min), "alive"], [T.kd == null ? kdOf(T) : f2(T.kd), `K/D (${T.kills}/${T.deaths})`], [f2(T.dpm), `deaths / min${T.lo != null ? ` (${f2(T.lo)}–${f2(T.hi)})` : ""}`],
      [pct(T.hit), "shots landed"], [pct(T.one_pct), "one-shot deaths"], [T.sessions, "sessions"]] : [["–", "no play data in this range"]]).map(([v, l]) => html`<div class="tile"><b>${v}</b><span>${l}</span></div>`)}</div>
    <div class="grid grid--even">
      <div class="card"><div class="card-h"><h2>Activity</h2><span class="fine muted">minutes alive per day</span></div><div class="card-b">${P.days.length ? html`<div class="days">${P.days.map(d =>
        html`<div class="d" title="${d.day}: ${mins(d.min)}, ${d.kills} kills, ${d.deaths} deaths, ${d.dpm != null ? f2(d.dpm) + " deaths/min" : ""}"><em>${d.kills}/${d.deaths}</em><i data-h="${Math.max(2, d.min / maxMin * 100)}"></i><span>${d.day.slice(8)}</span></div>`)}</div>
        <p class="fine muted">Labels above the bars: kills/deaths that day.</p>` : html`<p class="empty">No play data.</p>`}</div></div>
      <div class="card"><div class="card-h"><h2>Weapons</h2><span class="fine muted">kills / deaths holding it</span></div><div class="card-b card-b--flush">${tbl(["Weapon", ">Kills", ">Deaths"],
        P.weapons.map(([w, kk, dd]) => html`<tr><td>${w}</td><td class="r num">${kk}</td><td class="r num">${dd}</td></tr>`), "No kills or deaths.")}</div></div>
      <div class="card"><div class="card-h"><h2>Killed by most</h2><span class="fine muted">likely killer, a guess</span></div><div class="card-b bars">${P.killers.length ? P.killers.map(([n, c]) =>
        html`<div class="bar"><span class="lab" title="${n}">${n}</span><i data-w="${c / P.killers[0][1] * 100}"></i><span class="n">${c}</span></div>`) : html`<p class="hint">No deaths.</p>`}</div></div>
      <div class="card"><div class="card-h"><h2>By server</h2></div><div class="card-b card-b--flush">${tbl(["Server", ">Alive", ">K/D", ">Deaths / min", ">Hit"],
        P.srv.map(x => html`<tr><td>${{ nospread: "no spread", spread: "spread", unknown: "unknown" }[x.srv] || x.srv}</td><td class="r num">${mins(x.min)}</td><td class="r num">${x.kd == null ? kdOf(x) : f2(x.kd)}</td><td class="r num">${f2(x.dpm)}</td><td class="r num">${pct(x.hit)}</td></tr>`), "No data.")}</div></div>
    </div>
    <div class="card"><div class="card-h"><h2>Sessions</h2><span class="fine muted">${P.sessions.length} shown</span></div><div class="table-wrap" id="pp-s">${tbl(["When", "Build", ">Alive", ">Kills", ">Deaths", ">K/D", ">Deaths / min", ">Hit"],
      P.sessions.map(x => html`<tr class="click" data-s="${x.session}" tabindex="0"><td class="num nowrap">${day(x.a)} ${hm(x.a)}–${hm(x.b)}</td><td>${x.build}${x.ch === "beta" ? html` <span class="pill pill--acc">beta</span>` : ""}</td>
        <td class="r num">${mins(x.min)}</td><td class="r num">${x.kills}</td><td class="r num">${x.deaths}</td><td class="r num">${x.kd == null ? kdOf(x) : f2(x.kd)}</td><td class="r num">${f2(x.dpm)}</td><td class="r num">${pct(x.hit)}</td></tr>`), "No sessions in this range.")}</div></div>
    <div class="grid grid--even">
      <div class="card"><div class="card-h"><h2>Cloud configs</h2><span class="fine muted">${P.configs.length}</span></div><div class="table-wrap" id="pp-c">${tbl(["Config", ">Settings", "Code", "Saved"],
        P.configs.map(c => html`<tr class="click" data-n="${c.name}" tabindex="0"><td><b>${c.name}</b></td><td class="r num">${c.size}</td><td><code>${c.code || "–"}</code></td><td class="muted">${ago(c.ts)}</td></tr>`), "No saved configs.")}</div></div>
      <div class="card"><div class="card-h"><h2>Downloads</h2><span class="fine muted">${P.downloads.length}</span></div><div class="table-wrap">${tbl(["When", "Build", "Roblox id", "Address", "Download id"],
        P.downloads.map(d => html`<tr><td class="num nowrap">${when(d.ts)}</td><td class="mono">${d.build != null ? `#${d.build} ${d.ch || ""}` : d.ver}</td><td class="mono">${d.uid ?? "–"}</td><td class="mono">${d.ip}</td><td><code>${d.dl}</code></td></tr>`), "No copies downloaded.")}</div></div>
    </div>
    ${P.errors.length ? html`<div class="card"><div class="card-h"><h2>Script errors</h2></div><div class="table-wrap">${tbl(["When", "Build", "Where", "Error", ">Count"],
      P.errors.map(e => html`<tr><td class="num nowrap">${when(e.ts)}</td><td>${e.build}</td><td><code>${e.where}</code></td><td class="err-msg"><code>${e.msg}</code></td><td class="r num">${e.n}</td></tr>`), "")}</div></div>` : ""}`);
  $("#pp-act").onclick = e => { const b = e.target.closest("button[data-op]"); if (b && k) licAct(licObj(pseudo), b.dataset.op, +b.dataset.d || 0); };
  if ($("#pp-live")) $("#pp-live").onclick = () => { if (setAcct(name)) go("t/live"); };
  $("#pp-s").onclick = e => { const tr = e.target.closest("tr[data-s]"); if (tr) go(`t/session/${encodeURIComponent(tr.dataset.s)}`); };
  $("#pp-c").onclick = e => { const tr = e.target.closest("tr[data-n]"); if (tr) configDialog(name, tr.dataset.n); };
}
async function configDialog(acct, name) {
  let c; try { c = await api("GET", `library/item?acct=${encodeURIComponent(acct)}&name=${encodeURIComponent(name)}`); } catch (e) { return fail(e); }
  const show = v => typeof v === "boolean" ? (v ? "On" : "Off") : String(v);
  const d = dialog(html`<form><div class="dlg-h"><h2>${c.name}</h2><p>by ${c.acct} · ${when(c.ts)} · code <code>${c.code || "–"}</code> · ${Object.keys(c.data).length} settings</p></div>
    <div class="dlg-b dlg-b--scroll"><table class="vtable"><tbody>${groupedRows(c.data, k => html`<tr><td class="k"><code>${itemOf(k)}</code></td><td>${show(c.data[k])}</td><td></td></tr>`)}</tbody></table></div>
    <div class="dlg-f"><button class="btn btn--danger" type="button" id="cd-del">Delete</button><button class="btn" type="button" data-close>Close</button><button class="btn btn--primary" type="submit">Publish as official…</button></div></form>`,
    async (_f, dd) => { dd.close(); st.libItem = c; publishDialog(c); });
  d.classList.add("dlg--wide");
  d.addEventListener("close", () => d.classList.remove("dlg--wide"), { once: true });
  $("#cd-del").onclick = async () => {
    d.close();
    if (!await confirmBox(`Delete ${c.name} by ${c.acct}?`, "It disappears from their in-game list and its share code stops working. This cannot be undone.", "Delete", true)) return;
    try { await api("POST", "library", { op: "delete", acct: c.acct, name: c.name }); toast("Deleted"); route(); } catch (x) { fail(x); }
  };
}
function publishDialog(c) {
  dialog(html`<form><div class="dlg-h"><h2>Publish as official</h2><p>Every player will see it at the top of their Configs list. Same name replaces that preset.</p></div>
    <div class="dlg-b"><label class="field"><span>Name players see</span><input name="as" maxlength="24" value="${c.name}" required></label>
    <label class="field"><span>Note (admin only)</span><input name="note" maxlength="140" value="${"from " + c.acct}"></label></div>
    <div class="dlg-f"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn--primary" type="submit">Publish</button></div></form>`,
    async (f, dd) => { const r = await api("POST", "library", { op: "publish", acct: c.acct, name: c.name, as: f.get("as"), note: f.get("note") });
      dd.close(); toast(`${r.name} is live for every player`); st.preSel = r.name; });
}

// ================= PLAYERS: SERVED COPIES =================
async function pDownloads() {
  put($("#page"), html`<div class="stack"><div class="tiles" id="dl-tiles"></div><div class="card"><div class="card-h"><h2>Served copies</h2>
    <input class="inp search" id="dl-q" type="search" placeholder="Download id, key, Roblox id or address" value="${st.dlQ}"></div><div class="table-wrap" id="dl-t"><p class="empty">Loading…</p></div></div>
    <p class="hint">Every copy a player downloads is stamped with their key name, Roblox id and a download id. Paste the id from a leaked file to find who it came from, then revoke their key.</p></div>`);
  let r; try { r = await api("GET", "script"); } catch (e) { return fail(e); }
  const today = r.downloads.filter(d => now() - d.ts < 86400);
  put($("#dl-tiles"), html`${[[today.length, "copies today"], [new Set(today.map(d => d.acct)).size, "players today"], [r.downloads.length, "in this list (newest 60)"]]
    .map(([v, k]) => html`<div class="tile"><b>${v}</b><span>${k}</span></div>`)}`);
  const draw = () => { const q = st.dlQ.trim().toLowerCase(); const rows = r.downloads.filter(d => !q || [d.dl, d.acct, d.ip, d.uid].some(x => String(x ?? "").toLowerCase().includes(q)));
    put($("#dl-t"), rows.length ? html`<table><thead><tr><th>When</th><th>Key</th><th>Roblox id</th><th>Address</th><th>Build</th><th>Download id</th></tr></thead><tbody>${rows.map(d =>
      html`<tr><td class="num">${when(d.ts)}</td><td><a href="#p/player/${encodeURIComponent(d.acct)}">${d.acct}</a></td><td class="mono">${d.uid ?? "–"}</td><td class="mono">${d.ip}</td><td class="mono">${d.build != null ? `#${d.build} ${d.ch} ` : ""}${d.ver}</td><td><code>${d.dl}</code></td></tr>`)}</tbody></table>`
      : html`<p class="empty">${r.downloads.length ? "Nothing matches." : "No copies served yet."}</p>`); };
  $("#dl-q").oninput = e => { st.dlQ = e.target.value; draw(); }; draw();
}

boot();
