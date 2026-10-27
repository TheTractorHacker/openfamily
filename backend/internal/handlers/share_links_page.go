package handlers

import "html/template"

// shareGonePage is the single body served for every unusable token (unknown,
// malformed, expired, revoked): it must not reveal which.
const shareGonePage = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex,nofollow"><meta name="referrer" content="no-referrer">
<title>Link expired</title>
<style>
body{font-family:system-ui,sans-serif;margin:0;padding:24px;background:#f6f7f9;color:#1b1f24}
main{max-width:30rem;margin:12vh auto 0;background:#fff;border-radius:16px;padding:24px;box-shadow:0 1px 4px rgba(0,0,0,.12)}
h1{font-size:1.4rem;margin-top:0}
@media (prefers-color-scheme:dark){body{background:#101317;color:#e6e8eb}main{background:#1a1f25}}
</style></head>
<body><main><h1>This link has expired</h1>
<p>The person stopped sharing their location, or the time they chose ran out. Ask them to send a new link if you still need it.</p>
</main></body></html>`

// shareViewTmpl is the live viewer. Everything is inline (CSP nonce for the
// script); the only network contact besides this server is the operator's tile
// server. The script contains no template actions.
var shareViewTmpl = template.Must(template.New("shareview").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex,nofollow"><meta name="referrer" content="no-referrer">
<meta name="of-tiles" content="{{.Tiles}}">
<title>Live location</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--fg:#1b1f24;--muted:#5f6770;--accent:#1a73e8;--warn:#b3261e}
@media (prefers-color-scheme:dark){:root{--bg:#101317;--card:#1a1f25;--fg:#e6e8eb;--muted:#9aa3ad;--accent:#8ab4f8;--warn:#f2b8b5}}
*{box-sizing:border-box}
[hidden]{display:none!important}
html,body{height:100%;margin:0}
body{font-family:system-ui,sans-serif;background:var(--bg);color:var(--fg);display:flex;flex-direction:column}
#map{position:relative;flex:1;min-height:40vh;overflow:hidden;background:#dfe3e8;touch-action:none}
#tiles{position:absolute;left:0;top:0;will-change:transform}
#tiles img{position:absolute;width:256px;height:256px;max-width:none;user-select:none;-webkit-user-drag:none}
#acc{position:absolute;border-radius:50%;background:rgba(26,115,232,.15);border:1px solid rgba(26,115,232,.5);transform:translate(-50%,-50%);pointer-events:none}
#pin{position:absolute;width:48px;height:48px;margin:-24px 0 0 -24px;border-radius:50%;border:3px solid #fff;background:var(--accent);color:#fff;
 display:flex;align-items:center;justify-content:center;font-weight:700;font-size:22px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.4)}
#pin img{width:100%;height:100%;object-fit:cover}
.zoom{position:absolute;right:12px;top:12px;display:flex;flex-direction:column;gap:8px}
.zoom button{width:44px;height:44px;border-radius:50%;border:0;background:var(--card);color:var(--fg);font-size:22px;box-shadow:0 1px 4px rgba(0,0,0,.35)}
#attr{position:absolute;left:0;bottom:0;font-size:11px;padding:2px 6px;background:rgba(255,255,255,.8);color:#333}
#card{background:var(--card);padding:16px 16px calc(16px + env(safe-area-inset-bottom));box-shadow:0 -2px 8px rgba(0,0,0,.15)}
#name{font-size:1.25rem;font-weight:700;margin:0}
#meta{margin:4px 0 0;color:var(--muted);font-size:.95rem;overflow-wrap:anywhere}
#status{margin:8px 0 0;font-weight:600}
#status.warn{color:var(--warn)}
#gone{display:none;position:fixed;inset:0;background:var(--bg);align-items:center;justify-content:center;padding:24px;text-align:center}
#gone div{max-width:26rem}
body.gone #gone{display:flex}
</style></head>
<body>
<div id="map" aria-label="Map showing the shared location">
 <div id="tiles"></div><div id="acc" hidden></div><div id="pin" hidden></div>
 <div class="zoom"><button id="zin" aria-label="Zoom in">+</button><button id="zout" aria-label="Zoom out">&minus;</button></div>
 <div id="attr">Map data &copy; OpenStreetMap contributors</div>
</div>
<section id="card" aria-live="polite">
 <h1 id="name">Loading&hellip;</h1>
 <p id="status"></p>
 <p id="meta"></p>
</section>
<div id="gone" role="alert"><div><h1>This link has expired</h1>
<p>The person stopped sharing their location, or the time they chose ran out. Ask them to send a new link if you still need it.</p></div></div>
<script nonce="{{.Nonce}}">
(function () {
  "use strict";
  var token = location.pathname.split("/")[2] || "";
  var base = "/s/" + encodeURIComponent(token);
  var tileTpl = (document.querySelector('meta[name="of-tiles"]') || {}).content || "";
  var T = 256, zoom = 16, MINZ = 3, MAXZ = 19;
  var map = document.getElementById("map"), layer = document.getElementById("tiles");
  var pin = document.getElementById("pin"), accEl = document.getElementById("acc");
  var nameEl = document.getElementById("name"), statusEl = document.getElementById("status"), metaEl = document.getElementById("meta");
  var tiles = {};          // "z/x/y" -> img
  var cur = null, from = null, to = null, animStart = 0, raf = 0; // lat/lon objects
  var data = null, gone = false, timer = 0, photoFor = "";
  var imperial = /^en-(US|GB)/.test(navigator.language || "");

  function world(lat, lon, z) {
    var s = T * Math.pow(2, z), sin = Math.sin(lat * Math.PI / 180);
    sin = Math.max(-0.9999, Math.min(0.9999, sin));
    return { x: (lon + 180) / 360 * s, y: (0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * s };
  }
  function tileUrl(z, x, y) {
    return tileTpl.replace("{z}", z).replace("{x}", x).replace("{y}", y)
      .replace("{s}", ["a", "b", "c"][(x + y) % 3]);
  }
  function render() {
    if (!cur || !tileTpl) return;
    var w = map.clientWidth, h = map.clientHeight, c = world(cur.lat, cur.lon, zoom);
    var left = c.x - w / 2, top = c.y - h / 2;
    layer.style.transform = "translate(" + (-left) + "px," + (-top) + "px)";
    var n = Math.pow(2, zoom);
    var x0 = Math.floor(left / T), x1 = Math.floor((left + w) / T);
    var y0 = Math.max(0, Math.floor(top / T)), y1 = Math.min(n - 1, Math.floor((top + h) / T));
    for (var x = x0; x <= x1; x++) for (var y = y0; y <= y1; y++) {
      var wx = ((x % n) + n) % n, key = zoom + "/" + x + "/" + y;
      if (tiles[key]) continue;
      var im = new Image();
      im.referrerPolicy = "origin"; // origin only, never the secret path
      im.alt = ""; im.draggable = false;
      im.style.left = (x * T) + "px"; im.style.top = (y * T) + "px";
      im.src = tileUrl(zoom, wx, y);
      layer.appendChild(im); tiles[key] = im;
    }
    for (var k in tiles) if (k.split("/")[0] != zoom) { layer.removeChild(tiles[k]); delete tiles[k]; }
    pin.style.left = w / 2 + "px"; pin.style.top = h / 2 + "px";
    if (data && data.accuracy_m > 0) {
      var r = data.accuracy_m / (156543.03 * Math.cos(cur.lat * Math.PI / 180) / Math.pow(2, zoom));
      accEl.hidden = r < 6 || r > 600;
      accEl.style.width = accEl.style.height = (2 * r) + "px";
      accEl.style.left = w / 2 + "px"; accEl.style.top = h / 2 + "px";
    } else accEl.hidden = true;
  }
  function step(now) {
    var t = Math.min(1, (now - animStart) / 1000), e = 1 - Math.pow(1 - t, 3);
    cur = { lat: from.lat + (to.lat - from.lat) * e, lon: from.lon + (to.lon - from.lon) * e };
    render();
    raf = t < 1 ? requestAnimationFrame(step) : 0;
  }
  function moveTo(lat, lon) {
    if (!cur) { cur = { lat: lat, lon: lon }; to = cur; render(); return; }
    if (to && to.lat === lat && to.lon === lon) return;
    from = { lat: cur.lat, lon: cur.lon }; to = { lat: lat, lon: lon };
    animStart = performance.now();
    if (!raf) raf = requestAnimationFrame(step);
  }
  function setPin(d) {
    if (photoFor === (d.photo_url || "") && pin.firstChild) return;
    photoFor = d.photo_url || "";
    pin.textContent = "";
    if (photoFor) {
      var im = new Image(); im.alt = d.name;
      im.onerror = function () { pin.textContent = d.initial; };
      im.src = photoFor; pin.appendChild(im);
    } else pin.textContent = d.initial;
  }
  function ago(ts) {
    var s = Math.max(0, Math.round((Date.now() - new Date(ts).getTime()) / 1000));
    if (s < 60) return s + "s ago";
    if (s < 3600) return Math.floor(s / 60) + " min ago";
    if (s < 86400) return Math.floor(s / 3600) + " h ago";
    return Math.floor(s / 86400) + " d ago";
  }
  function paint() {
    if (!data) return;
    nameEl.textContent = data.name;
    document.title = data.name + " - live location";
    statusEl.className = "";
    var meta = [];
    if (data.state === "paused") {
      statusEl.textContent = "Sharing paused"; statusEl.className = "warn";
      metaEl.textContent = "Location will reappear when " + data.name + " resumes sharing.";
    } else if (data.state === "no_location") {
      statusEl.textContent = "Waiting for a location"; metaEl.textContent = "";
    } else {
      statusEl.textContent = "Last updated " + ago(data.updated_at);
      if (data.battery_pct != null) meta.push("Battery " + Math.round(data.battery_pct) + "%");
      if (data.speed_mps != null && data.speed_mps > 0.5) {
        meta.push(imperial ? Math.round(data.speed_mps * 2.23694) + " mph" : Math.round(data.speed_mps * 3.6) + " km/h");
      }
      var mins = Math.max(0, Math.round((new Date(data.expires_at).getTime() - Date.now()) / 60000));
      meta.push("Sharing ends in " + (mins >= 60 ? Math.floor(mins / 60) + " h " + (mins % 60) + " min" : mins + " min"));
      metaEl.textContent = meta.join(" · ");
    }
  }
  function apply(d) {
    data = d; setPin(d);
    var live = d.state === "active";
    pin.hidden = !live; if (!live) accEl.hidden = true;
    if (live) { moveTo(d.lat, d.lon); pin.hidden = false; }
    paint();
  }
  function end() {
    gone = true; clearInterval(timer); document.body.classList.add("gone");
  }
  function poll() {
    if (gone || document.visibilityState === "hidden") return;
    fetch(base + "/data", { cache: "no-store", credentials: "omit", referrerPolicy: "no-referrer" })
      .then(function (r) {
        if (r.status === 404) { end(); return null; }
        if (!r.ok) return null; // 429/5xx: keep the last view, retry on the next tick
        return r.json();
      })
      .then(function (d) { if (d) apply(d); })
      .catch(function () { statusEl.textContent = "Reconnecting…"; });
  }
  function setZoom(z) { zoom = Math.max(MINZ, Math.min(MAXZ, z)); render(); }
  document.getElementById("zin").onclick = function () { setZoom(zoom + 1); };
  document.getElementById("zout").onclick = function () { setZoom(zoom - 1); };
  window.addEventListener("resize", render);
  document.addEventListener("visibilitychange", function () { if (document.visibilityState === "visible") poll(); });
  setInterval(paint, 1000);
  timer = setInterval(poll, 5000);
  poll();
})();
</script>
</body></html>`))
