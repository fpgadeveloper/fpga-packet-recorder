// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Opsero Electronic Design Inc.
// pktrec-web single-page UI: polls /api/stats every second, /api/status every 5 s.
"use strict";

const $ = (id) => document.getElementById(id);
let status = null, stats = null, lastCapState = null, busy = false;

async function api(method, path, body) {
  const opt = { method, headers: {} };
  if (body !== undefined) { opt.body = JSON.stringify(body); opt.headers["Content-Type"] = "application/json"; }
  const r = await fetch(path, opt);
  let j = null;
  try { j = await r.json(); } catch (e) { /* empty body */ }
  if (!r.ok) throw new Error((j && j.error) || `${r.status} ${r.statusText}`);
  return j;
}

function esc(s) { return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
function si(v, unit, d = 1) {
  if (v === null || v === undefined || isNaN(v)) return "—";
  const a = Math.abs(v);
  if (a >= 1e9) return (v / 1e9).toFixed(d) + " G" + unit;
  if (a >= 1e6) return (v / 1e6).toFixed(d) + " M" + unit;
  if (a >= 1e3) return (v / 1e3).toFixed(d) + " k" + unit;
  return v.toFixed(0) + " " + unit;
}
function bytes(v) { return v === null || v === undefined ? "—" : si(v, "B", v >= 1e9 ? 2 : 1); }
function dur(s) {
  if (s === null || s === undefined) return "—";
  s = Math.max(0, s);
  const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, sec = s % 60;
  return h ? `${h}h ${m}m ${sec.toFixed(0)}s` : m ? `${m}m ${sec.toFixed(0)}s` : `${sec.toFixed(1)} s`;
}
function bar(el, frac) {
  frac = Math.max(0, Math.min(1, frac || 0));
  el.style.width = (frac * 100).toFixed(1) + "%";
  el.className = frac > 0.9 ? "bad" : frac > 0.7 ? "warn" : "";
}
function msg(text, cls) { const m = $("cmsg"); m.textContent = text || ""; m.className = "msg " + (cls || ""); }

// ---- ports and pair modes ----
function renderPorts() {
  if (!status) return;
  const cnt = (stats && stats.counters && stats.counters.ports) || {};
  const fifo = stats && stats.counters && stats.counters.fifo_bytes;
  $("ports").innerHTML = status.ports.map((p) => {
    const c = cnt[p.port] || p.counters || {};
    const link = p.link ? `${esc(p.speed || "")} ${p.duplex === "half" ? "HD" : p.duplex ? "FD" : ""}` : (p.error ? "error" : "down");
    return `<div class="card${p.link ? "" : " down"}">
      <h3><span><span class="dot${p.link ? " up" : ""}"></span>P${p.port}</span><small>${esc(link)}</small></h3>
      <div class="row"><span>Path</span><b>${esc(p.path || "—")}</b></div>
      <div class="row"><span>Frames/s</span><b>${si(c.frames_s, "", 2)}</b></div>
      <div class="row"><span>Bits/s</span><b>${si(c.bits_s, "b/s", 2)}</b></div>
      <div class="row"><span>Frames</span><b>${c.frames_rx ?? "—"}</b></div>
      <div class="row${c.frames_drop ? " drops" : ""}"><span>Drops</span><b>${c.frames_drop ?? "—"}</b></div>
      <div class="row"><span>FIFO high-water</span><b>${c.fifo_hwm !== undefined && fifo ? ((100 * c.fifo_hwm) / fifo).toFixed(0) + " %" : "—"}</b></div>
    </div>`;
  }).join("");
  const running = status.capture && status.capture.state !== "idle";
  // rebuild the pair cards only when something they show changed (keeps focus and tooltips)
  const key = JSON.stringify([running, status.pairs.map((q) => [q.mode, q.paths,
    q.ports.map((n) => { const p = status.ports[n] || {}; return [p.link, p.speed, p.duplex, p.error]; })])]);
  if (key === pairsKey) return;
  pairsKey = key;
  $("pairs").innerHTML = status.pairs.map((q) => `<div class="paircard">
      <div class="ph">
        <b>P${q.ports[0]}/P${q.ports[1]}</b>
        <span class="seg">${["tap", "monitor"].map((m) => `<button data-pair="${q.pair}" data-mode="${m}" class="${q.mode === m ? "on" : ""}" ${running ? "disabled title=\"stop the capture first\"" : ""}>${m === "tap" ? "TAP" : "Monitor"}</button>`).join("")}</span>
      </div>
      <small class="pd">${MODE_TEXT[q.mode] || (q.mode === "other" ? "custom paths: " + esc((q.paths || []).join("/")) : "mode unknown")}</small>
      <figure>${pairFigure(q)}
        <figcaption><b>${q.mode === "tap" ? "TAP" : q.mode === "monitor" ? "Monitor" : q.mode === "other" ? "Custom" : "Unknown"}</b> mode</figcaption>
        <div class="legend"><span><i class="up"></i>link up</span><span><i class="down"></i>link down</span>${q.mode === "tap" ? `<span><i class="fwd"></i>forwarded</span>` : ""}<span><i class="rec"></i>recorded</span></div>
      </figure>
    </div>`).join("");
}

const MODE_TEXT = {
  tap: "TAP: forwarded through the fabric, both directions captured",
  monitor: "monitor: receive only",
};
let pairsKey = null;

// Connectivity figure of one pair (inline SVG; colours come from CSS variables / currentColor).
// Ports face down: cables from the devices enter their fronts; their back ends go to the fabric.
function pairFigure(q) {
  const id = "f" + q.pair, X = [70, 180], W = 50, Y = 66, H = 34, DEV = ["device A", "device B"];
  const mode = q.mode;
  const ports = q.ports.map((n, i) => {
    const p = (status.ports && status.ports[n]) || {}, x = X[i], cx = x + W / 2;
    const up = !!p.link, cls = up ? "up" : "down";
    const st = up ? `link up${p.speed ? " " + p.speed : ""}${p.duplex ? (p.duplex === "half" ? " HD" : " FD") : ""}` : (p.error ? "error" : "link down");
    return `<g class="port ${cls}"><title>P${n}: ${esc(st)}${p.path ? ", path " + esc(p.path) : ""}</title>
        <rect class="body" x="${x}" y="${Y}" width="${W}" height="${H}" rx="4"/>
        <path class="jack" d="M${cx - 12} ${Y + H - 4}v-15h24v15h-7v4h-10v-4z"/>
        <circle class="led" cx="${x + W - 7}" cy="${Y + 7}" r="3.2"/>
        <text x="${i ? x + W + 8 : x - 8}" y="${Y + H / 2 + 4}" text-anchor="${i ? "start" : "end"}">P${n}</text>
      </g>
      <g><title>Ethernet cable from ${DEV[i]} to P${n}</title>
        <path class="cable${up ? "" : " down"}" d="M${cx} ${Y + H + 9}V${Y + H + 34}"/>
        <rect class="plug" x="${cx - 7}" y="${Y + H}" width="14" height="9" rx="1.5"/>
        <text class="dim" x="${cx}" y="${Y + H + 48}" text-anchor="middle">${DEV[i]}</text>
      </g>`;
  }).join("");
  const c0 = X[0] + W / 2, c1 = X[1] + W / 2, mid = (c0 + c1) / 2, top = Y - 1;
  const hdd = `<g class="hdd"><title>SSD: the capture file</title>
      <rect x="${mid - 28}" y="4" width="56" height="28" rx="4"/>
      <circle cx="${mid - 12}" cy="18" r="8.5"/><circle class="hub" cx="${mid - 12}" cy="18" r="2"/>
      <text x="${mid + 13}" y="22" text-anchor="middle">SSD</text></g>`;
  const defs = `<defs>
      <marker id="${id}a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path class="arr-fwd" d="M0 0L10 5L0 10z"/></marker>
      <marker id="${id}r" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path class="arr-rec" d="M0 0L10 5L0 10z"/></marker></defs>`;
  let paths = "", label = "";
  if (mode === "tap") {
    paths = `<g><title>Inline forwarding path in the fabric: P${q.ports[0]} ↔ P${q.ports[1]}</title>
        <path class="fwd" d="M${c0} ${top}V50H${c1}V${top}" marker-start="url(#${id}a)" marker-end="url(#${id}a)"/></g>
      <g><title>Both directions are recorded: each port records what it receives</title>
        <path class="recl tapline" d="M${mid} 50V34" marker-end="url(#${id}r)"/><circle class="arr-rec" cx="${mid}" cy="50" r="2.6"/></g>`;
    label = "TAP: devices A and B talk through the board; both directions recorded";
  } else if (mode === "monitor") {
    paths = q.ports.map((n, i) => `<g><title>P${n} receives only and records to the SSD; nothing is forwarded</title>
        <path class="recl" d="M${i ? c1 : c0} ${top}L${i ? mid + 14 : mid - 14} 34" marker-end="url(#${id}r)"/></g>`).join("");
    label = "Monitor: both ports receive only and record; nothing forwarded";
  } else {
    label = mode === "other" ? "custom per-port paths (set with pktrec-phy path)" : "mode unknown";
  }
  return `<svg class="fig" viewBox="0 0 300 150" role="img" aria-label="P${q.ports[0]}/P${q.ports[1]} ${esc(label)}">
      <title>${esc(label)}</title>${defs}${hdd}${paths}${ports}</svg>`;
}

$("pairs").addEventListener("click", async (ev) => {
  const b = ev.target.closest("button[data-pair]");
  if (!b || b.classList.contains("on")) return;
  try {
    await api("POST", "/api/mode", { pair: +b.dataset.pair, mode: b.dataset.mode });
    msg(`P${2 * b.dataset.pair}/P${2 * b.dataset.pair + 1}: ${b.dataset.mode} mode`, "ok");
  } catch (e) { msg(e.message, "err"); }
  pollStatus();
});

// ---- timebase discipline (pktrec-tb) and calibration ----
function usec(ns) { return ns === null || ns === undefined ? "—" : (ns >= 0 ? "+" : "") + (ns / 1e3).toFixed(1) + " µs"; }
function renderTimebase() {
  if (!status) return;
  const t = (status.time && status.time.discipline) || {}, c = status.calibration || {};
  let state, cls;
  if (!t.daemon || !t.fresh) { state = "not disciplined (pktrec-tb not running): timestamps drift from wall-clock time"; cls = "warn"; }
  else if (t.locked) { state = `locked to system time${t.ntp_synced === false ? " (system clock NOT NTP-synced)" : t.ntp_synced ? " (NTP)" : ""}`; cls = t.ntp_synced === false ? "warn" : "ok"; }
  else { state = `tracking, not locked yet (${esc(t.state || "?")})`; cls = "warn"; }
  const ap = c.applied;
  const calTxt = !c.present ? "no calibration file (design defaults)" :
    ap ? `calibration ${ap.ok ? "applied" : "applied with errors"} ${(ap.applied || "").replace("T", " ").replace(/\.\d+Z$/, " UTC")}` : "calibration file present, not applied since boot";
  $("tb").innerHTML = `<div class="pair">
      <span><b>Timebase</b> <small class="${cls}">${state}</small></span>
      <span><small>offset ${usec(t.offset_ns)}${t.offset_rms_ns != null ? ` (rms ${(t.offset_rms_ns / 1e3).toFixed(1)} µs)` : ""} · trim ${t.ppm != null ? (t.ppm >= 0 ? "+" : "") + t.ppm.toFixed(3) + " ppm" : "—"} · ${esc(calTxt)}</small></span>
    </div>`;
}

// ---- capture ----
function renderCapture(cap, disk) {
  const running = cap.state !== "idle";
  $("start").disabled = running || busy || (disk && !disk.mounted);
  $("stop").disabled = !running || busy;
  $("cstate").textContent = cap.state + (disk && !disk.mounted ? " (SSD not mounted)" : "");
  const live = cap.live || {};
  if (running) {
    $("cfile").textContent = cap.name + ".cap";
    $("celapsed").textContent = dur(cap.elapsed_s) + (cap.duration_s ? ` / ${dur(cap.duration_s)}` : "");
    $("cbytes").textContent = bytes(cap.file_bytes) + (cap.size_bytes ? ` / ${bytes(cap.size_bytes)}` : "");
    $("crate").textContent = live.write_mb_s !== undefined ? live.write_mb_s.toFixed(1) + " MB/s" : "—";
    $("ring").textContent = live.ring_total ? `${live.ring_used}/${live.ring_total}` : "—";
    bar($("ringbar"), live.ring_total ? live.ring_used / live.ring_total : 0);
  } else {
    const l = cap.last;
    $("cfile").textContent = l ? `last: ${l.name}.cap` : "—";
    $("celapsed").textContent = l && l.result && l.result.seconds !== undefined ? dur(l.result.seconds) : "—";
    $("cbytes").textContent = l && l.result && l.result.bytes !== undefined ? bytes(l.result.bytes) : "—";
    $("crate").textContent = "—"; $("ring").textContent = "—"; bar($("ringbar"), 0);
  }
  if (disk && disk.mounted) {
    $("disk").textContent = `${bytes(disk.free_bytes)} of ${bytes(disk.total_bytes)}`;
    bar($("diskbar"), 1 - disk.free_bytes / disk.total_bytes);
  } else { $("disk").textContent = "not mounted"; bar($("diskbar"), 0); }
  // state transitions: report the result, refresh the list
  if (lastCapState && lastCapState !== "idle" && cap.state === "idle") {
    const l = cap.last;
    if (l) msg(l.exit_code === 0 ? `${l.name}: complete, lossless` : `${l.name}: ${l.message || "exit " + l.exit_code}`, l.exit_code === 0 ? "ok" : l.exit_code === 2 ? "warn" : "err");
    loadCaptures();
  } else if (lastCapState === null && cap.state !== "idle") { loadCaptures(); }
  if (running && cap.log && cap.log.length && !$("cmsg").textContent) msg(cap.log[cap.log.length - 1]);
  lastCapState = cap.state;
}

$("capform").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const ports = [...document.querySelectorAll("input[name=port]:checked")].map((x) => +x.value);
  if (!ports.length) { msg("select at least one port", "err"); return; }
  const body = { ports, snaplen: +$("snaplen").value || 0 };
  const d = parseFloat($("duration").value), s = parseFloat($("size").value);
  if (d > 0) body.duration_s = d;
  if (s > 0) body.size_bytes = Math.round(s * parseFloat($("sizeunit").value));
  if ($("capname").value.trim()) body.name = $("capname").value.trim();
  busy = true; msg("starting…");
  try {
    const st = await api("POST", "/api/capture/start", body);
    msg(st.state === "idle" ? "capture ended immediately" : `capturing to ${st.name}.cap`, "ok");
    $("capname").value = "";
    loadCaptures();
  } catch (e) { msg(e.message, "err"); }
  busy = false; pollStats();
});

$("stop").addEventListener("click", async () => {
  busy = true; msg("stopping…");
  try { await api("POST", "/api/capture/stop"); } catch (e) { msg(e.message, "err"); }
  busy = false; pollStats();
});

// ---- captures table ----
async function loadCaptures() {
  let j;
  try { j = await api("GET", "/api/captures"); } catch (e) { return; }
  const tb = $("caps").querySelector("tbody");
  if (!j.captures.length) { tb.innerHTML = `<tr><td colspan="7"><small>No captures in ${esc(j.disk.path)}/captures</small></td></tr>`; return; }
  tb.innerHTML = j.captures.map((c) => {
    const n = encodeURIComponent(c.name);
    const start = c.start_time ? c.start_time.replace("T", " ").replace(/\.\d+Z$/, "") : (c.mtime || "").replace("T", " ").replace(/\.\d+Z$/, "");
    return `<tr class="${c.recording ? "rec" : ""}">
      <td>${esc(c.name)}${c.error ? ` <small title="${esc(c.error)}">(unreadable)</small>` : ""}</td>
      <td>${esc(start)}</td>
      <td class="num">${c.recording ? "—" : dur(c.duration_s)}</td>
      <td class="num">${bytes(c.file_bytes)}</td>
      <td>${(c.ports_captured || []).map((p) => "P" + p).join(" ")}</td>
      <td class="num${c.drops ? " drops" : ""}">${c.drops ?? (c.complete === false && !c.recording ? "incomplete" : "—")}</td>
      <td class="act">${c.recording ? "" : `<a class="btn" href="/api/captures/${n}.pcapng" download>pcapng</a><a class="btn" href="/api/captures/${n}.cap" download>raw</a>`}
        <button data-info="${esc(c.name)}">info</button>${c.recording ? "" : `<button data-del="${esc(c.name)}">delete</button>`}</td>
    </tr>`;
  }).join("");
}

$("caps").addEventListener("click", async (ev) => {
  const info = ev.target.closest("button[data-info]"), del = ev.target.closest("button[data-del]");
  if (info) {
    try {
      const h = await api("GET", `/api/captures/${encodeURIComponent(info.dataset.info)}/info`);
      $("infotitle").textContent = h.name + ".cap";
      $("infotext").textContent = h.info_text || JSON.stringify(h, null, 2);
      $("infodlg").showModal();
    } catch (e) { msg(e.message, "err"); }
  } else if (del) {
    if (!confirm(`Delete ${del.dataset.del}.cap? This cannot be undone.`)) return;
    try { await api("DELETE", `/api/captures/${encodeURIComponent(del.dataset.del)}`); msg(`deleted ${del.dataset.del}`, "ok"); }
    catch (e) { msg(e.message, "err"); }
    loadCaptures();
  }
});
$("refresh").addEventListener("click", loadCaptures);

// ---- theme (follows the system; the header button overrides it, remembered per browser) ----
const THEME_KEY = "pktrec-theme", darkMq = window.matchMedia ? matchMedia("(prefers-color-scheme: dark)") : null;
function effectiveTheme() {
  const t = document.documentElement.dataset.theme;
  return t === "light" || t === "dark" ? t : darkMq && darkMq.matches ? "dark" : "light";
}
function showThemeButton() {
  const dark = effectiveTheme() === "dark", b = $("theme"), t = `Switch to ${dark ? "light" : "dark"} theme`;
  b.classList.toggle("dark", dark); b.title = t; b.setAttribute("aria-label", t);
}
$("theme").addEventListener("click", () => {
  const next = effectiveTheme() === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = next;
  try { localStorage.setItem(THEME_KEY, next); } catch (e) { /* storage blocked: this page only */ }
  showThemeButton();
});
if (darkMq && darkMq.addEventListener) darkMq.addEventListener("change", showThemeButton);
showThemeButton();

// ---- polling ----
function setConn(ok, text) { const c = $("conn"); c.textContent = text; c.className = "pill " + (ok ? "ok" : "bad"); }

async function pollStats() {
  try {
    stats = await api("GET", "/api/stats");
    setConn(true, "connected");
    renderCapture(stats.capture, stats.disk);
    if (status) { status.capture = stats.capture; renderPorts(); }
  } catch (e) { setConn(false, "disconnected"); }
}

async function pollStatus() {
  try {
    status = await api("GET", "/api/status");
    renderPorts();
    renderTimebase();
    const v = status.version || {}, t = status.time || {};
    $("footer").textContent = `pktrec-web ${v.web || "?"} · capture block ${v.capture_block || "?"} · ${v.image || "image ?"} · board time ${t.system ? t.system.replace("T", " ").replace(/\.\d+Z$/, " UTC") : "?"}` +
      (status.errors && (status.errors["pktrec-phy"] || status.errors["pktrec-cap"]) ? ` · tool error: ${status.errors["pktrec-phy"] || status.errors["pktrec-cap"]}` : "");
  } catch (e) { setConn(false, "disconnected"); }
}

pollStatus(); pollStats(); loadCaptures();
setInterval(pollStats, 1000);
setInterval(pollStatus, 5000);
setInterval(loadCaptures, 15000);
