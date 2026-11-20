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
function widths(el) { $$("[data-w]", el).forEach(x => { x.style.width = x.dataset.w + "%"; }); }
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
  page: "overrides", acct: "", sess: "latest", S: null, lic: [], presets: [], schema: {}, preSel: null, draft: null, dirty: false,
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
  rs_mode: "Resolver", rs_lead: "Lead (ticks, -1 = ping)", rs_take: "Take over after misses", rs_max: "Largest desync guess",
  rs_baim: "Body aim after misses", rs_multi: "Candidate resolver", rs_pitch: "Force their usual pitch", rs_fd: "Safe point on fake duck",
  hc_air: "Hit chance in air", hc_noscope: "Hit chance unscoped", hc_duck: "Hit chance crouched", mindmg: "Minimum damage floor", lethal: "Lethal shots only",
};
const GROUPS = [
  ["Anti-aim", /^(enabled|pitch|up_fix|yaw_|mod_|lag|anim)/], ["Desync", /^(inverter|lim_|delay)/], ["Defensive", /^def_/],
  ["On-shot", /^os_/], ["Peek", /^peek_/], ["Dodge", /^dodge/], ["Resolver", /^rs_/], ["Rage", /^(hc_|mindmg|lethal)/],
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
const PAGES = {
  overrides: ["Live overrides", "Push settings to players while they play. The game applies them within about 5 seconds."],
  presets: ["Official presets", "Configs every subscriber sees first in the in-game Configs page and can load."],
  library: ["Player configs", "Every config your subscribers saved to the cloud, with its share code."],
  licenses: ["Licenses", "Keys, expiry, the Roblox account each key is locked to, and live sessions."],
  live: ["Live", "What is happening in game right now."],
  stats: ["Stats and export", "Where deaths come from, per config version, and raw data downloads."],
  script: ["Script and downloads", "The build players get, the loader line, and every copy that was served."],
};
function route() {
  const p = (location.hash || "#overrides").slice(1);
  st.page = PAGES[p] ? p : "overrides";
  $$(".side-nav a").forEach(a => { if (a.dataset.page === st.page) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current"); });
  $("#page-title").textContent = PAGES[st.page][0]; $("#page-sub").textContent = PAGES[st.page][1];
  document.title = PAGES[st.page][0] + " · unsyk admin";
  $("#top-tools").innerHTML = ""; $("#page").innerHTML = ""; $("#page").style.animation = "none"; void $("#page").offsetWidth; $("#page").style.animation = "";
  closeSide(); $(".dock")?.remove();
  ({ overrides: pOverrides, presets: pPresets, library: pLibrary, licenses: pLicenses, live: pLive, stats: pStats, script: pScript })[st.page]();
}
window.addEventListener("hashchange", () => {
  if (st.dirty && !confirm("Leave without saving this preset?")) { history.replaceState(null, "", "#presets"); return; }
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
  timers.push(setInterval(() => { if (!document.hidden && ["overrides", "live", "stats"].includes(st.page)) loadStatus().then(rerender).catch(fail); }, 10000));
  timers.push(setInterval(() => { if (!document.hidden && st.page === "live") pollLive().catch(() => {}); }, 2500));
}
function stopTimers() { while (timers.length) clearInterval(timers.pop()); }
async function loadStatus() {
  st.S = await api("GET", `status?session=${encodeURIComponent(st.sess)}&acct=${encodeURIComponent(st.acct)}`);
  const age = st.S.last_event ? now() - st.S.last_event : 1e9;
  $("#feed-dot").className = "dot" + (age < 20 ? " dot--on" : "");
  return st.S;
}
function rerender() { if (st.page === "overrides") drawOverrides(); if (st.page === "live") drawLive(); if (st.page === "stats") drawStats(); }
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
  const ctl = (k, spec, v) => {
    if (spec.t === "b") return html`<div class="tri" role="group" aria-label="${KEYINFO[k] || k}">${[["", "Unset"], ["true", "On"], ["false", "Off"]].map(([val, lab]) =>
      html`<button type="button" data-k="${k}" data-v="${val}" aria-pressed="${(v === undefined ? "" : String(v)) === val}">${lab}</button>`)}</div>`;
    if (spec.t === "c") return html`<select data-k="${k}" aria-label="${KEYINFO[k] || k}"><option value="">Not set</option>${spec.o.map(o =>
      html`<option value="${o}" ${raw(v === o ? "selected" : "")}>${o}</option>`)}</select>`;
    const mid = Math.round((spec.lo + spec.hi) / 2);
    return html`<input type="range" data-k="${k}" min="${spec.lo}" max="${spec.hi}" step="1" value="${v ?? mid}" aria-label="${KEYINFO[k] || k}">
      <input type="number" data-k="${k}" min="${spec.lo}" max="${spec.hi}" step="1" value="${v ?? ""}" placeholder="–" aria-label="${(KEYINFO[k] || k) + " value"}">`;
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
      const state = dirty ? html`${giving ? html`<span class="pill pill--warn">give back</span>` : ""}<button class="btn btn--ghost btn--sm" type="button" data-undo="${k}">Undo</button>`
        : over ? html`<button class="btn btn--ghost btn--sm" type="button" data-unset="${k}" title="Give the setting back to the player">Give back</button>`
        : fromAll ? html`<span class="pill" title="From the everyone layer">all: ${String(inh[k])}</span>` : html`<span class="pill">player's</span>`;
      return html`<div class="krow ${cls}"><div class="klabel"><b>${KEYINFO[k] || k}</b><code>${k}${spec.t === "n" ? ` · ${spec.lo} to ${spec.hi}` : ""}</code>${over && scoped && k in inh ? html` <span class="fine muted">everyone: ${String(inh[k])}</span>` : ""}</div>
        <div class="kctl">${ctl(k, spec, v)}</div><div class="kstate">${state}</div></div>`;
    })}</section>`);
  }
  put($("#ov"), html`<div class="card-h"><div><h2>${scoped ? `Overrides for ${st.acct}` : "Overrides for everyone"}</h2>
    <p class="muted">${scoped ? "On top of the everyone layer. Dashed = inherited from everyone." : "Every player gets these unless their account overrides the same setting."} Config v${C.v || 0}.</p></div></div>${body}`);
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
    <p class="hint">Players see these at the top of the in-game Configs list, marked official, in this order. Load only: players cannot change or delete them.</p></div>
    <div class="card" id="pr-ed"></div></div>`);
  $("#pr-new").onclick = () => newDraft({ name: "", note: "", data: {} });
  await loadPresets();
  if (st.preSel && st.presets.find(p => p.name === st.preSel)) selPreset(st.preSel); else if (st.presets[0]) selPreset(st.presets[0].name); else drawEditor();
}
async function loadPresets() {
  try { const r = await api("GET", "presets"); st.presets = r.presets; st.schema = r.schema; st.presetMax = r.max; } catch (e) { return fail(e); }
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
}
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
  put(ed, html`<div class="card-h"><div><h2>${d.isNew ? "New preset" : d.orig}</h2><p class="muted">${Object.keys(d.data).length} settings${d.isNew ? "" : " · published"}</p></div>
    <div class="toolbar">${d.isNew ? "" : html`<button class="btn btn--sm" type="button" id="ed-dup">Duplicate</button><button class="btn btn--sm btn--danger" type="button" id="ed-del">Unpublish</button>`}
    <button class="btn btn--sm" type="button" id="ed-json">JSON</button><button class="btn btn--primary btn--sm" type="button" id="ed-save">${d.isNew ? "Publish" : "Save"}</button></div></div>
    <div class="editor-head"><label class="field"><span>Name players see</span><input class="inp" id="ed-name" maxlength="24" value="${d.name}" placeholder="e.g. Scout HvH"></label>
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

// ================= LICENSES =================
async function pLicenses() {
  put($("#page"), html`<div class="stack"><div class="tiles" id="lic-tiles"></div><div class="card"><div class="card-h"><div class="seg" id="lic-f" role="group" aria-label="Filter"></div>
    <input class="inp search" id="lic-q" type="search" placeholder="Search name or Roblox user" value="${st.licQ}"></div><div class="table-wrap" id="lic-t"></div></div>
    <p class="hint">A key locks to the first Roblox account that logs in and works on one device at a time: a new login ends the old session and the script stops there within about a minute. Revoking, ending the session or unbinding stops the script the same way.</p></div>`);
  const add = document.createElement("button"); add.className = "btn btn--primary"; add.type = "button"; add.textContent = "New key"; add.onclick = newKey;
  $("#top-tools").append(add);
  $("#lic-q").oninput = e => { st.licQ = e.target.value; drawLic(); };
  $("#lic-f").onclick = e => { const b = e.target.closest("button[data-f]"); if (b) { st.licFilter = b.dataset.f; drawLic(); } };
  await refreshLic();
}
async function refreshLic() { try { await loadLic(); } catch (e) { return fail(e); } drawLic(); }
const licState = k => k.state === "active" ? "active" : k.state.includes("expired") ? "expired" : "revoked";
function drawLic() {
  const ks = st.lic, c = { all: ks.length, active: 0, expired: 0, revoked: 0 }; ks.forEach(k => c[licState(k)]++);
  const soon = ks.filter(k => licState(k) === "active" && k.expires && k.expires - now() < 3 * 86400).length;
  put($("#lic-tiles"), html`<div class="tile"><b>${c.active}</b><span>active keys</span></div><div class="tile"><b>${ks.filter(k => k.online).length}</b><span>in game now</span></div>
    <div class="tile"><b>${soon}</b><span>end within 3 days</span></div><div class="tile"><b>${c.expired + c.revoked}</b><span>expired or revoked</span></div>`);
  put($("#lic-f"), html`${["all", "active", "expired", "revoked"].map(f => html`<button type="button" data-f="${f}" aria-pressed="${st.licFilter === f}">${f[0].toUpperCase() + f.slice(1)} <span class="count">${c[f]}</span></button>`)}`);
  const q = st.licQ.trim().toLowerCase();
  const rows = ks.filter(k => (st.licFilter === "all" || licState(k) === st.licFilter) && (!q || [k.name, k.user, k.note].some(x => String(x || "").toLowerCase().includes(q))));
  const pill = k => { const s = licState(k); return html`<span class="pill ${s === "active" ? (k.expires && k.expires - now() < 3 * 86400 ? "pill--warn" : "pill--good") : "pill--bad"}">${s}</span>`; };
  put($("#lic-t"), rows.length ? html`<table><thead><tr><th>Key</th><th>Status</th><th>Expires</th><th>Roblox account</th><th>Seen</th><th class="r">Logins</th><th class="r">Downloads</th><th class="r">K/D</th><th></th></tr></thead>
    <tbody>${rows.map(k => html`<tr><td><b>${k.name}</b><span class="sub">${k.note || "id " + k.id}</span></td><td>${pill(k)}</td>
      <td class="num">${k.expires ? day(k.expires) : "never"}<span class="sub">${left(k.expires)}</span></td>
      <td>${k.uid ? html`${k.user || "?"}<span class="sub mono">${k.uid}</span>` : html`<span class="muted">not bound yet</span>`}</td>
      <td>${k.online ? html`<span class="pill pill--good"><span class="dot dot--on"></span>in game</span>` : ago(k.seen || k.last)}${k.ver ? html`<span class="sub mono">${k.ver}</span>` : ""}</td>
      <td class="r num">${k.logins}</td><td class="r num">${k.downloads}</td><td class="r num">${k.deaths ? (k.kills / k.deaths).toFixed(2) : k.kills || "–"}</td>
      <td class="r"><div class="menu"><button class="btn btn--ghost btn--sm" type="button" data-menu="${k.name}" aria-haspopup="true" aria-label="Actions for ${k.name}">•••</button></div></td></tr>`)}</tbody></table>`
    : html`<p class="empty">${ks.length ? "No key matches." : "No keys yet. Make the first one with New key."}</p>`);
  $("#lic-t").onclick = e => { const b = e.target.closest("[data-menu]"); if (b) licMenu(b, st.lic.find(k => k.name === b.dataset.menu)); };
}
function licMenu(btn, k) {
  $$(".menu-pop").forEach(m => m.remove());
  const pop = document.createElement("div"); pop.className = "menu-pop"; pop.setAttribute("role", "menu");
  const act = licState(k) === "revoked" ? ["enable", "Enable key"] : ["revoke", "Revoke key"];
  put(pop, html`<button type="button" data-op="add_days" data-d="7">Add 7 days</button><button type="button" data-op="add_days" data-d="30">Add 30 days</button>
    <button type="button" data-op="set">Set expiry…</button><button type="button" data-op="note">Edit note…</button><hr>
    <button type="button" data-op="kick">End live session</button><button type="button" data-op="reset" ${raw(k.uid ? "" : "disabled")}>Unbind Roblox account</button>
    <button type="button" data-op="${act[0]}" class="${act[0] === "revoke" ? "bad" : ""}">${act[1]}</button><button type="button" data-op="delete" class="bad">Delete key</button>`);
  btn.parentElement.append(pop); $("button", pop).focus();
  const close = ev => { if (!pop.contains(ev.target)) { pop.remove(); document.removeEventListener("pointerdown", close, true); } };
  setTimeout(() => document.addEventListener("pointerdown", close, true));
  pop.onkeydown = e => { if (e.key === "Escape") { pop.remove(); btn.focus(); } };
  pop.onclick = async e => {
    const b = e.target.closest("button[data-op]"); if (!b) return; pop.remove();
    const op = b.dataset.op;
    const run = async (body, msg) => { try { await api("POST", "licenses", { name: k.name, ...body }); toast(msg); await refreshLic(); } catch (x) { fail(x); } };
    if (op === "add_days") return run({ op, days: +b.dataset.d }, `${k.name}: +${b.dataset.d} days`);
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
    if (ask && await confirmBox(...ask)) run({ op }, `${k.name}: ${ask[2].toLowerCase()} done`);
  };
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
      d.addEventListener("close", () => { put(d, html``); }, { once: true });
      refreshLic();
    });
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

// ================= STATS =================
async function pStats() {
  put($("#page"), html`<div class="stack"><div class="tiles" id="sx-tiles"></div><div class="grid grid--even">
    <div class="card"><div class="card-h"><h2>Deaths by ticks since our flip</h2></div><div class="card-b bars" id="b-flip"></div></div>
    <div class="card"><div class="card-h"><h2>Likely killers</h2></div><div class="card-b bars" id="b-killer"></div></div>
    <div class="card"><div class="card-h"><h2>Deaths by my state</h2></div><div class="card-b bars" id="b-state"></div></div>
    <div class="card"><div class="card-h"><h2>Killer weapon</h2></div><div class="card-b bars" id="b-killer_wep"></div></div>
    <div class="card"><div class="card-h"><h2>Deaths by my weapon</h2></div><div class="card-b bars" id="b-weapon"></div></div>
    <div class="card"><div class="card-h"><h2>My misses</h2><p class="muted">not counting deaths</p></div><div class="card-b bars" id="b-miss"></div></div></div>
    <div class="card"><div class="card-h"><h2>By config version</h2><p class="muted">Compare deaths per minute before and after a push.</p></div><div class="card-b card-b--flush table-wrap" id="sx-cv"></div></div>
    <div class="grid grid--even"><div class="card"><div class="card-h"><h2>Full report</h2><div class="toolbar"><select class="inp" id="r-since" aria-label="Range"><option value="">Whole session</option><option value="10m">Last 10 min</option><option value="30m">Last 30 min</option><option value="2h">Last 2 h</option></select>
      <select class="inp" id="r-scope" aria-label="Sessions"><option value="sel">Picked session</option><option value="all">All sessions</option></select><button class="btn btn--sm" type="button" id="r-go">Run</button></div></div>
      <div class="card-b"><pre class="report muted" id="r-out">Pick a range and press Run.</pre></div></div>
    <div class="card"><div class="card-h"><h2>Export data</h2></div><div class="card-b stack"><p class="hint">CSV or JSON lines for the account picked at the top, or everyone. Nested fields become a.b columns.</p>
      <div class="toolbar"><select class="inp" id="x-kind" aria-label="Data">${["deaths", "hits", "shots", "intel", "state", "ctrl", "uploads", "all"].map(k => html`<option>${k}</option>`)}</select>
      <select class="inp" id="x-since" aria-label="Range"><option value="">All time</option><option value="2h">Last 2 h</option><option value="24h">Last 24 h</option><option value="7d">Last 7 days</option></select>
      <select class="inp" id="x-fmt" aria-label="Format"><option>csv</option><option>jsonl</option></select><button class="btn btn--primary btn--sm" type="button" id="x-go">Download</button></div></div></div></div>
    <p class="hint">“Likely killer” is a guess (the only scoped enemy, else the nearest): the game has no attacker event. Small samples are noise.</p></div>`);
  try { await Promise.all([loadStatus(), loadLic()]); } catch (e) { return fail(e); }
  $("#top-tools").append(scopeSeg(async () => { await loadStatus().catch(fail); drawStats(); }));
  $("#r-go").onclick = async () => {
    const s = $("#r-scope").value === "all" ? "all" : (st.sess === "latest" ? st.S?.session || "latest" : st.sess);
    $("#r-out").textContent = "Running…";
    try { $("#r-out").textContent = await api("GET", `report?session=${encodeURIComponent(s)}&since=${$("#r-since").value}&acct=${encodeURIComponent(st.acct)}`); $("#r-out").classList.remove("muted"); }
    catch (e) { fail(e); }
  };
  $("#x-go").onclick = () => { location.href = `/admin/api/export?kind=${encodeURIComponent($("#x-kind").value)}&format=${encodeURIComponent($("#x-fmt").value)}&since=${encodeURIComponent($("#x-since").value)}&acct=${encodeURIComponent(st.acct)}`; };
  drawStats();
}
function drawStats() {
  const S = st.S; if (!S || !$("#sx-tiles")) return;
  put($("#sx-tiles"), tilesFor(S.totals));
  for (const k of ["flip", "state", "weapon", "killer", "killer_wep", "miss"]) {
    const list = S.dist[k] || [], max = Math.max(1, ...list.map(x => x[1]));
    put($("#b-" + k), list.length ? html`${list.map(([lab, n]) => html`<div class="bar"><span class="lab" title="${lab}">${lab}</span><i data-w="${Math.max(3, n / max * 100)}"></i><span class="n">${n}</span></div>`)}`
      : html`<p class="hint">No data yet.</p>`);
  }
  put($("#sx-cv"), S.by_cv.length ? html`<table><thead><tr><th>Config</th><th class="r">Minutes</th><th class="r">Deaths</th><th class="r">Kills</th><th class="r">Deaths / min</th><th>Note</th></tr></thead><tbody>${[...S.by_cv].reverse().map(c =>
    html`<tr><td>v${c.v}</td><td class="r num">${c.min}</td><td class="r num">${c.deaths}</td><td class="r num">${c.kills}</td><td class="r num">${c.dpm ?? "–"}</td><td class="fine">${c.note || ""}</td></tr>`)}</tbody></table>`
    : html`<p class="empty">No data yet.</p>`);
}

// ================= SCRIPT =================
async function pScript() {
  let r; try { r = await api("GET", "script"); } catch (e) { return fail(e); }
  const line = `loadstring(game:HttpGet("${r.base}/loader.lua"))()`;
  put($("#page"), html`<div class="stack"><div class="tiles"><div class="tile"><b class="mono">${r.ver || "–"}</b><span>build served now</span></div>
    <div class="tile"><b>${r.mtime ? r.mtime.slice(5) : "–"}</b><span>deployed</span></div><div class="tile"><b>${Math.round(r.size / 1024)} KB</b><span>size, obfuscated</span></div>
    <div class="tile"><b>${r.downloads.filter(d => now() - d.ts < 86400).length}</b><span>copies served today</span></div></div>
    <div class="grid grid--even"><div class="card"><div class="card-h"><h2>Loader line</h2><button class="btn btn--sm" type="button" id="sc-copy">Copy</button></div>
      <div class="card-b stack"><code class="mono">${line}</code><p class="hint">Players paste this once. The loader holds no secrets: without a valid key it downloads nothing.</p></div></div>
    <div class="card"><div class="card-h"><h2>Files</h2></div><div class="card-b stack"><div class="toolbar"><a class="btn btn--sm" href="/admin/api/download?f=script">Download build (owner copy)</a>
      <a class="btn btn--sm" href="/admin/api/download?f=loader">Download loader.lua</a></div>
      <p class="hint">Every copy a player downloads is stamped with their key name, Roblox id and a download id, and logged below. A leaked file names its source.</p></div></div></div>
    <div class="card"><div class="card-h"><h2>Served copies</h2><input class="inp search" id="dl-q" type="search" placeholder="Download id, key or address" value="${st.dlQ}"></div><div class="table-wrap" id="dl-t"></div></div></div>`);
  $("#sc-copy").onclick = () => copy(line, "Loader line copied");
  const draw = () => { const q = st.dlQ.trim().toLowerCase(); const rows = r.downloads.filter(d => !q || [d.dl, d.acct, d.ip, d.uid].some(x => String(x ?? "").toLowerCase().includes(q)));
    put($("#dl-t"), rows.length ? html`<table><thead><tr><th>When</th><th>Key</th><th>Roblox id</th><th>Address</th><th>Build</th><th>Download id</th></tr></thead><tbody>${rows.map(d =>
      html`<tr><td class="num">${when(d.ts)}</td><td>${d.acct}</td><td class="mono">${d.uid ?? "–"}</td><td class="mono">${d.ip}</td><td class="mono">${d.ver}</td><td><code>${d.dl}</code></td></tr>`)}</tbody></table>`
      : html`<p class="empty">${r.downloads.length ? "Nothing matches." : "No copies served yet."}</p>`); };
  $("#dl-q").oninput = e => { st.dlQ = e.target.value; draw(); }; draw();
}

boot();
