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
  $("pairs").innerHTML = status.pairs.map((q) => `<div class="pair">
      <span><b>P${q.ports[0]}/P${q.ports[1]}</b> <small>${q.mode === "tap" ? "TAP: forwarded through the fabric, both directions captured" : q.mode === "monitor" ? "monitor: receive only" : q.mode === "other" ? "custom paths: " + esc(q.paths.join("/")) : "unknown"}</small></span>
      <span class="seg">${["tap", "monitor"].map((m) => `<button data-pair="${q.pair}" data-mode="${m}" class="${q.mode === m ? "on" : ""}" ${running ? "disabled title=\"stop the capture first\"" : ""}>${m === "tap" ? "TAP" : "Monitor"}</button>`).join("")}</span>
    </div>`).join("");
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
    const v = status.version || {}, t = status.time || {};
    $("footer").textContent = `pktrec-web ${v.web || "?"} · capture block ${v.capture_block || "?"} · ${v.image || "image ?"} · board time ${t.system ? t.system.replace("T", " ").replace(/\.\d+Z$/, " UTC") : "?"}` +
      (status.errors && (status.errors["pktrec-phy"] || status.errors["pktrec-cap"]) ? ` · tool error: ${status.errors["pktrec-phy"] || status.errors["pktrec-cap"]}` : "");
  } catch (e) { setConn(false, "disconnected"); }
}

pollStatus(); pollStats(); loadCaptures();
setInterval(pollStats, 1000);
setInterval(pollStatus, 5000);
setInterval(loadCaptures, 15000);
