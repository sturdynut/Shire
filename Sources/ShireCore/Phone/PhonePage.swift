import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The phone page: one self-contained HTML file (no external requests), a manifest so it can live on the Home Screen,
/// and a service worker that shows pushed alerts.
enum PhonePage {
    static let manifest = """
    {
      "name": "Shire",
      "short_name": "Shire",
      "description": "Is my Mac server okay?",
      "start_url": "/",
      "scope": "/",
      "display": "standalone",
      "background_color": "#131312",
      "theme_color": "#131312",
      "icons": [
        { "src": "/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any" },
        { "src": "/apple-touch-icon.png", "sizes": "180x180", "type": "image/png" }
      ]
    }
    """

    static let serviceWorker = """
    self.addEventListener('install', () => self.skipWaiting());
    self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));
    self.addEventListener('push', (event) => {
      let data = {};
      try { data = event.data ? event.data.json() : {}; } catch (e) { data = { title: 'Shire', body: event.data ? event.data.text() : '' }; }
      const title = data.title || 'Shire';
      event.waitUntil(self.registration.showNotification(title, {
        body: data.body || '',
        tag: (data.service || 'shire') + ':' + (data.kind || ''),
        data: { service: data.service || '' },
        icon: '/apple-touch-icon.png',
      }));
    });
    self.addEventListener('notificationclick', (event) => {
      event.notification.close();
      const service = event.notification.data && event.notification.data.service;
      const url = service ? '/#/s/' + encodeURIComponent(service) : '/';
      event.waitUntil(self.clients.matchAll({ type: 'window' }).then((windows) => {
        for (const w of windows) { w.navigate(url); return w.focus(); }
        return self.clients.openWindow(url);
      }));
    });
    """

    static let iconSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 180 180"><rect width="180" height="180" rx="40" fill="#1E1D1B"/>\
    <rect x="42" y="50" width="96" height="32" rx="8" fill="none" stroke="#EFEDE7" stroke-width="7"/>\
    <rect x="42" y="98" width="96" height="32" rx="8" fill="none" stroke="#EFEDE7" stroke-width="7"/>\
    <circle cx="60" cy="66" r="5" fill="#EFEDE7"/><circle cx="60" cy="114" r="5" fill="#EFEDE7"/>\
    <circle cx="136" cy="136" r="16" fill="#5BCB86"/></svg>
    """

    /// The Home Screen icon (iOS wants a PNG), drawn once with Core Graphics.
    static let iconPNG: Data = {
        let size = 180
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        func color(_ hex: UInt32) -> CGColor {
            CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        // Core Graphics is y-up; the shapes are symmetric enough that it doesn't matter.
        context.setFillColor(color(0x1E1D1B))
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 180, height: 180), cornerWidth: 40, cornerHeight: 40, transform: nil))
        context.fillPath()
        context.setStrokeColor(color(0xEFEDE7))
        context.setLineWidth(7)
        for y in [98.0, 50.0] {
            context.addPath(CGPath(roundedRect: CGRect(x: 42, y: y, width: 96, height: 32), cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.strokePath()
            context.setFillColor(color(0xEFEDE7))
            context.fillEllipse(in: CGRect(x: 55, y: y + 11, width: 10, height: 10))
        }
        context.setFillColor(color(0x5BCB86))
        context.fillEllipse(in: CGRect(x: 120, y: 28, width: 32, height: 32))
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-title" content="Shire">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="theme-color" content="#131312" media="(prefers-color-scheme: dark)">
    <meta name="theme-color" content="#F6F5F1" media="(prefers-color-scheme: light)">
    <link rel="manifest" href="/manifest.webmanifest">
    <link rel="apple-touch-icon" href="/apple-touch-icon.png">
    <link rel="icon" href="/icon.svg">
    <title>Shire</title>
    <style>
    :root {
      --bg: #F6F5F1; --surface: #FFFFFF; --line: #E3E0D8; --ink: #1D1C1A; --ink2: #5C5953; --accent: #0E6B63;
      --good: #1E6B3C; --good-bg: #E3F1E7; --good-dot: #2E9E5B;
      --warn: #8A4B00; --warn-bg: #FBEBD2; --warn-dot: #D98A0B;
      --bad: #A1221B; --bad-bg: #FBE3E1; --bad-dot: #D93A2F;
      --off: #5C5953; --off-bg: #ECEAE4; --off-dot: #8A877F;
      --log: #1A1917; --log-ink: #E9E6DF;
      color-scheme: light;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #131312; --surface: #1E1D1B; --line: #2F2D2A; --ink: #EFEDE7; --ink2: #ABA79E; --accent: #6FD1C4;
        --good: #7EDBA2; --good-bg: #17301F; --good-dot: #5BCB86;
        --warn: #F5C27A; --warn-bg: #2B2415; --warn-dot: #F2AE45;
        --bad: #F8A39B; --bad-bg: #3A1F1C; --bad-dot: #F47A70;
        --off: #ABA79E; --off-bg: #262522; --off-dot: #7F7C74;
        color-scheme: dark;
      }
    }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--ink);
      font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; -webkit-text-size-adjust: 100%; }
    main { max-width: 560px; margin: 0 auto;
      padding: calc(env(safe-area-inset-top, 0px) + 20px) 16px calc(env(safe-area-inset-bottom, 0px) + 28px);
      display: flex; flex-direction: column; gap: 16px; }
    header { display: flex; align-items: flex-start; gap: 12px; }
    header .who { flex: 1; min-width: 0; }
    .eyebrow { font-size: 12.5px; color: var(--ink2); }
    h1 { margin: 2px 0 0; font-size: 30px; font-weight: 750; letter-spacing: -0.01em; overflow-wrap: anywhere; }
    h2 { margin: 6px 4px -6px; font-size: 13px; font-weight: 600; letter-spacing: .04em; color: var(--ink2); text-transform: uppercase; }
    button, a.button { font: inherit; }
    .refresh { min-height: 44px; padding: 0 12px; border-radius: 12px; border: 1px solid var(--line); background: var(--surface); color: var(--ink2);
      display: inline-flex; align-items: center; gap: 6px; font-size: 13px; }
    .card { background: var(--surface); border: 1px solid var(--line); border-radius: 14px; overflow: hidden; }
    .hero { padding: 18px; display: flex; flex-direction: column; gap: 10px; }
    .hero.good { background: var(--good-bg); } .hero.warn { background: var(--warn-bg); } .hero.off { background: var(--off-bg); }
    .hero .title { display: flex; align-items: center; gap: 10px; font-size: 22px; font-weight: 750; }
    .hero.good .title { color: var(--good); } .hero.warn .title { color: var(--warn); } .hero.off .title { color: var(--off); }
    .dot { width: 10px; height: 10px; border-radius: 50%; flex: none; }
    .dot.good { background: var(--good-dot); } .dot.warn { background: var(--warn-dot); } .dot.bad { background: var(--bad-dot); } .dot.off { background: var(--off-dot); }
    .row { display: flex; align-items: center; gap: 12px; padding: 12px 16px; min-height: 60px; color: inherit; text-decoration: none; border-bottom: 1px solid var(--line); }
    .row:last-child { border-bottom: none; }
    .row .text { flex: 1; min-width: 0; }
    .row .name { font-size: 15.5px; font-weight: 600; }
    .row .sub { font-size: 13px; color: var(--ink2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .state { font-size: 13.5px; font-weight: 600; white-space: nowrap; }
    .state.good { color: var(--good); } .state.warn { color: var(--warn); } .state.bad { color: var(--bad); } .state.off { color: var(--off); }
    .chev { color: var(--ink2); }
    .note { margin: 0 4px; font-size: 12.5px; color: var(--ink2); }
    .back { align-self: flex-start; min-height: 44px; display: inline-flex; align-items: center; color: var(--accent); text-decoration: none; font-size: 16px; margin: -8px 0 -8px -4px; }
    .pill { display: inline-flex; align-items: center; gap: 6px; height: 24px; padding: 0 10px; border-radius: 999px; font-size: 12.5px; font-weight: 600; }
    .pill.good { background: var(--good-bg); color: var(--good); } .pill.warn { background: var(--warn-bg); color: var(--warn); }
    .pill.bad { background: var(--bad-bg); color: var(--bad); } .pill.off { background: var(--off-bg); color: var(--off); }
    .mono { font-family: ui-monospace, "SF Mono", Menlo, monospace; }
    .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
    .stat { padding: 12px 14px; background: var(--surface); border: 1px solid var(--line); border-radius: 12px; }
    .stat .label { font-size: 12px; color: var(--ink2); }
    .stat .value { font-size: 17px; font-weight: 650; overflow-wrap: anywhere; }
    .cause { padding: 16px; display: flex; flex-direction: column; gap: 6px; }
    .cause .label { font-size: 12px; font-weight: 700; letter-spacing: .04em; color: var(--accent); }
    .logs { padding: 12px 14px; background: var(--log); color: var(--log-ink); font-size: 12px; line-height: 1.6;
      white-space: pre-wrap; word-break: break-word; max-height: 50vh; overflow: auto; border-radius: 14px; }
    .primary, .secondary { width: 100%; min-height: 50px; border-radius: 12px; font-size: 15.5px; font-weight: 650; border: 1px solid var(--line); }
    .primary { background: var(--accent); color: var(--bg); border-color: var(--accent); }
    .secondary { background: var(--surface); color: var(--ink); }
    .primary:disabled, .secondary:disabled { opacity: .5; }
    .sheet-backdrop { position: fixed; inset: 0; background: rgba(0,0,0,.45); display: flex; align-items: flex-end; justify-content: center; }
    .sheet { width: 100%; max-width: 560px; background: var(--surface); border-radius: 18px 18px 0 0;
      padding: 20px 16px calc(env(safe-area-inset-bottom, 0px) + 16px); display: flex; flex-direction: column; gap: 10px; }
    .sheet h3 { margin: 0; font-size: 18px; }
    .toast { position: fixed; left: 16px; right: 16px; bottom: calc(env(safe-area-inset-bottom, 0px) + 16px); max-width: 528px; margin: 0 auto;
      background: var(--ink); color: var(--bg); padding: 12px 14px; border-radius: 12px; font-size: 14px; }
    .alert { padding: 11px 16px; border-bottom: 1px solid var(--line); display: flex; gap: 12px; }
    .alert:last-child { border-bottom: none; }
    .alert time { font-size: 12.5px; color: var(--ink2); width: 44px; flex: none; padding-top: 1px; }
    .alert .body { color: var(--ink2); font-size: 13.5px; }
    .check { padding: 12px 16px; border-bottom: 1px solid var(--line); }
    .check:last-child { border-bottom: none; }
    .check .fix { color: var(--warn); font-size: 13.5px; margin-top: 4px; }
    .hidden { display: none !important; }
    </style>
    </head>
    <body>
    <main id="app" aria-live="polite"><p class="note">Loading…</p></main>
    <script>
    'use strict';
    let status = null;
    let refreshTimer = null;

    const $ = (html) => { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content; };
    const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const hhmm = (iso) => new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    const ago = (iso) => {
      const s = Math.max(0, Math.round((Date.now() - new Date(iso)) / 1000));
      return s < 60 ? s + ' s' : s < 3600 ? Math.round(s / 60) + ' min' : Math.round(s / 3600) + ' h';
    };
    const toneForLevel = (level) => level === 'ok' ? 'good' : level === 'warn' ? 'warn' : 'off';

    async function load() {
      try {
        const response = await fetch('/api/status', { cache: 'no-store' });
        status = await response.json();
        render();
      } catch (e) {
        document.getElementById('app').innerHTML = '<p class="note">Can’t reach this Mac. It may be asleep, off, or waiting at the login screen.</p>';
      }
    }

    function render() {
      if (!status) return;
      const route = location.hash.match(/^#\/s\/(.+)$/);
      const app = document.getElementById('app');
      app.replaceChildren(route ? serviceView(decodeURIComponent(route[1])) : homeView());
      document.title = route ? decodeURIComponent(route[1]) + ' · Shire' : 'Shire · ' + status.host;
    }

    function header() {
      return `<header><div class="who"><div class="eyebrow">Shire · via Tailscale</div><h1>${esc(status.host)}</h1></div>
        <button class="refresh" onclick="load()" aria-label="Refresh">↻ ${ago(status.updated)}</button></header>`;
    }

    function homeView() {
      const s = status;
      const firstBad = s.services.find((x) => x.tone === 'bad' || x.tone === 'warn');
      const services = s.services.map((x) => `<a class="row" href="#/s/${encodeURIComponent(x.name)}">
          <span class="dot ${x.tone}"></span><span class="text"><div class="name">${esc(x.name)}</div><div class="sub">${esc(x.detail)}</div></span>
          <span class="state ${x.tone}">${esc(x.state)}</span><span class="chev">›</span></a>`).join('');
      const system = s.system.map((r) => `<div class="row"><span class="dot ${toneForLevel(r.level)}"></span>
          <span class="text"><div class="name">${esc(r.name === 'keep-awake' ? 'Kept awake' : r.name === 'tailscale' ? 'Tailscale' : r.name)}</div>
          <div class="sub">${esc(r.value)}</div></span></div>`).join('');
      const readiness = s.readiness.map((c) => `<div class="check"><div class="name">${esc(c.title)}</div>
          ${c.fix ? `<div class="fix">→ ${esc(c.fix)}</div>` : `<div class="sub">${esc(c.detail)}</div>`}</div>`).join('');
      const alerts = s.alerts.slice(0, 5).map((a) => `<div class="alert"><time>${hhmm(a.time)}</time>
          <div><div class="name">${esc(a.title)}</div><div class="body">${esc(a.body)}</div></div></div>`).join('');
      return $(`${header()}
        <section class="card hero ${s.tone}"><div class="title"><span class="dot ${s.tone === 'warn' ? 'warn' : s.tone === 'good' ? 'good' : 'off'}"></span>${esc(s.headline)}</div>
          <div>${esc(s.summary)}</div>
          ${firstBad ? `<a class="button primary" style="display:flex;align-items:center;justify-content:center;text-decoration:none" href="#/s/${encodeURIComponent(firstBad.name)}">See what’s wrong ›</a>` : ''}
        </section>
        <h2>Services</h2><section class="card">${services || '<div class="row"><span class="sub">No services in config.yaml.</span></div>'}</section>
        <h2>This Mac</h2><section class="card">${system}</section>
        ${readiness ? `<h2>Could stop it serving</h2><section class="card">${readiness}</section>` : ''}
        ${alerts ? `<h2>Recent alerts</h2><section class="card">${alerts}</section>` : ''}
        <h2>Alerts on this phone</h2><section class="card cause" id="push">${pushSection()}</section>
        <p class="note">Only reachable on your tailnet. ${s.viewer.login ? 'Signed in as ' + esc(s.viewer.login) + '.' : ''}
          ${s.viewer.canRestart ? 'Restart asks before it acts.' : esc(s.viewer.reason || '')}</p>`);
    }

    function serviceView(name) {
      const x = status.services.find((s) => s.name === name);
      if (!x) return $(`<a class="back" href="#/">‹ ${esc(status.host)}</a><p class="note">No service named ${esc(name)}.</p>`);
      const stats = [
        ['Process', x.process],
        ['Health', x.health ? (x.tone === 'good' ? 'Healthy' : 'Failing') : 'No check'],
        x.lastExit !== null && x.lastExit !== undefined ? ['Last exit', String(x.lastExit)] : ['Detail', x.health || '—'],
        x.failures ? ['Restarts', `${x.failures} in ${x.window}`] : ['Checked', x.healthNote || '—'],
      ].map(([l, v]) => `<div class="stat"><div class="label">${esc(l)}</div><div class="value">${esc(v)}</div></div>`).join('');
      const fragment = $(`<a class="back" href="#/">‹ ${esc(status.host)}</a>
        <div><h1 style="font-size:28px">${esc(x.name)}</h1>
          <div style="display:flex;align-items:center;gap:10px;margin-top:8px"><span class="pill ${x.tone}"><span class="dot ${x.tone}" style="width:7px;height:7px"></span>${esc(x.state)}</span>
          <span class="mono" style="font-size:12.5px;color:var(--ink2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(x.command || '')}</span></div></div>
        <div class="grid">${stats}</div>
        ${x.cause ? `<section class="card cause"><div class="label">LIKELY CAUSE</div><div>${esc(x.cause)}</div></section>` : ''}
        ${x.external ? '<p class="note">Shire only watches this one; its own tools manage it.</p>' : `<h2>stderr · last lines</h2><pre class="logs mono" id="logs">Loading…</pre>`}
        ${x.external ? '' : `<button class="primary" id="restart" ${x.canRestart ? '' : 'disabled'}>Restart</button>
          <p class="note" style="text-align:center">${x.canRestart ? 'Asks to confirm first. Config changes stay on the Mac.' : esc(status.viewer.reason || '')}</p>`}`);
      if (!x.external) {
        fetch(`/api/services/${encodeURIComponent(name)}/logs?lines=12`).then((r) => r.json()).then((d) => {
          const el = document.getElementById('logs');
          if (el) el.textContent = (d.lines || []).join('\n') || 'No output yet.';
        }).catch(() => {});
        setTimeout(() => {
          const button = document.getElementById('restart');
          if (button) button.onclick = () => confirmRestart(name);
        });
      }
      return fragment;
    }

    function confirmRestart(name) {
      const sheet = $(`<div class="sheet-backdrop" id="sheet" role="dialog" aria-modal="true" aria-labelledby="sheet-title">
        <div class="sheet"><h3 id="sheet-title">Restart ${esc(name)}?</h3>
        <p class="note" style="margin:0">It stops and starts again now. Anyone using it will be interrupted for a moment.</p>
        <button class="primary" id="sheet-yes">Restart</button><button class="secondary" id="sheet-no">Cancel</button></div></div>`);
      document.body.appendChild(sheet);
      const close = () => document.getElementById('sheet')?.remove();
      document.getElementById('sheet-no').onclick = close;
      document.getElementById('sheet').onclick = (e) => { if (e.target.id === 'sheet') close(); };
      document.getElementById('sheet-yes').onclick = async () => {
        close();
        const response = await fetch(`/api/services/${encodeURIComponent(name)}/restart`, { method: 'POST', headers: { 'X-Shire': '1' } });
        const body = await response.json().catch(() => ({}));
        toast(body.message || (response.ok ? 'Restarting.' : 'Couldn’t restart.'));
        setTimeout(load, 3000);
      };
    }

    function toast(text) {
      const el = document.createElement('div');
      el.className = 'toast';
      el.setAttribute('role', 'status');
      el.textContent = text;
      document.body.appendChild(el);
      setTimeout(() => el.remove(), 3500);
    }

    // ---- Push ------------------------------------------------------------

    const standalone = () => window.navigator.standalone === true || window.matchMedia('(display-mode: standalone)').matches;
    const pushSupported = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;

    function pushSection() {
      const p = status.push;
      if (!p.enabled) return '<div>Phone alerts are off. Turn them on with <span class="mono">alerts: { phone: true }</span> in config.yaml.</div>';
      if (!status.viewer.canRestart && !status.viewer.login) return '<div>Open this page through Tailscale to turn on alerts.</div>';
      if (!standalone()) return '<div>Add this page to your Home Screen first (Share → Add to Home Screen), then open it from there to turn on alerts.</div>';
      if (!pushSupported()) return '<div>This browser can’t receive push alerts.</div>';
      if (Notification.permission === 'granted' && localStorage.getItem('shire-subscribed') === 'yes') {
        return '<div>Alerts are on for this phone.</div><button class="secondary" onclick="testPush()">Send a test alert</button>';
      }
      if (Notification.permission === 'denied') return '<div>Notifications are blocked for this app in iOS Settings → Notifications → Shire.</div>';
      return '<div>Get a notification when something breaks, even when this page is closed.</div><button class="primary" onclick="enablePush()">Turn on alerts</button>';
    }

    function keyBytes(base64url) {
      const padded = (base64url + '==='.slice((base64url.length + 3) % 4)).replace(/-/g, '+').replace(/_/g, '/');
      return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
    }

    async function enablePush() {
      try {
        const permission = await Notification.requestPermission();
        if (permission !== 'granted') { toast('Notifications weren’t allowed.'); render(); return; }
        const registration = await navigator.serviceWorker.ready;
        const subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(status.push.publicKey) });
        const response = await fetch('/api/push/subscribe', { method: 'POST', headers: { 'X-Shire': '1', 'Content-Type': 'application/json' }, body: JSON.stringify(subscription) });
        if (!response.ok) throw new Error((await response.json().catch(() => ({}))).message || 'The Mac refused the subscription.');
        localStorage.setItem('shire-subscribed', 'yes');
        toast('Alerts are on for this phone.');
        load();
      } catch (e) {
        toast(String(e.message || e));
      }
    }

    async function testPush() {
      const response = await fetch('/api/push/test', { method: 'POST', headers: { 'X-Shire': '1' } });
      toast(response.ok ? 'Sent. It should arrive in a few seconds.' : 'Couldn’t send a test.');
    }

    if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
    window.addEventListener('hashchange', render);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) load(); });
    load();
    refreshTimer = setInterval(load, 15000);
    </script>
    </body>
    </html>
    """#
}
