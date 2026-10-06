# Long-polling fallback (2026-10-06)

The public pages are served through a proxy that does not relay WebSockets.
The compiled asset `priv/static/assets/app-cc8e354438fc2f7f034d911e1e4196fd.js` of the
upstream 1.15.7 release is modified with one change, then re-compressed (`gzip -9`, `zstd -19`)
and mounted read-only over the original files:

```diff
-{params:{_csrf_token:Wn,timezone:zn()},hooks:ls}
+{params:{_csrf_token:Wn,timezone:zn()},hooks:ls,transport:location.hostname==="nouvelles-entreprises-rdv.vercel.app"?_e:void 0,longPollFallbackMs:2500}
```

This is the `longPollFallbackMs` option of Phoenix LiveView's `LiveSocket`: when the WebSocket
cannot connect within 2.5 s, the page falls back to HTTP long polling. Runtime configuration:
`PHX_HOST` set to the public host and `WS_ALLOWED_ORIGINS` listing it.

On the public host the LongPoll transport (`_e` in the bundle) is used from the first load. `facade-ne-charte.js` is appended
to the same asset: branding (stylesheet, logo, favicon, title) and a guard that submits once the primary button becomes
enabled when a click lands on it while still disabled.
