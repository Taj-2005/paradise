# Phase 2 configuration bundle (spec §9)

The **rendered** configs exactly as installed on each machine during the
23 Nov 2026 run. They are generated from the committed templates plus `.env`
(`make render`, `make p2-render`), so the templates remain the source of truth.
These copies exist so an evaluator can read the real values without running
anything. No private keys are included, only certificate *paths*.

| File | Installed on | Rendered from | What to look at |
|---|---|---|---|
| `primary-dns-mac1.dnsmasq.conf` | Mac 1, `/opt/homebrew/etc/dnsmasq.conf` | `infra/mac1-dns/dnsmasq.conf.template` | `local-ttl=30` (Ext B); `address=/app.paradise.test/10.7.3.123` |
| `backup-dns-mac4.dnsmasq.conf` | Mac 4, same path | same template | identical records and TTL; forwards public names to `1.1.1.1`, **never to Mac 1** (Ext A) |
| `primary-edge-mac2.site.conf` | Mac 2, `/opt/homebrew/etc/nginx/conf.d/site.conf` | `infra/mac2-edge/nginx/conf.d/site.conf.template` | `max_fails=1 fail_timeout=10s`, `proxy_next_upstream` (Ext D); `keepalive_timeout 4s` (Incident 2 fix) |
| `standby-edge-mac4.nginx.conf` + `standby-edge-mac4.site.conf` | Mac 4, standby nginx | the **same** Phase 1 templates | same upstreams and certificate as Mac 2 (Ext E) |
| `pf-backend-a-mac3.conf` | Mac 3, pf anchor `com.apple/250.ParadiseIsolation` | `infra/phase2/pf/backend-isolation.pf.tpl` | `pass … from { 10.7.3.123, 10.7.18.17 } … port 3001`, then `block drop` (Ext C) |
| `pf-backend-b-mac4.conf` | Mac 4, same anchor | same template | same, for port 3002 |

Phase 1's configs are in `evidence/A-lan-dns/A2-dnsmasq.txt` and
`evidence/B-https-lb/B3-nginx.conf`. TLS certificate setup notes:
`infra/mac2-edge/certs/README.md` (Phase 1) and `infra/phase2/certs/README.md`
(copying the certificate to the standby edge). Backend launch:
`infra/mac3-backend-a/README.md`, `infra/mac4-backend-b/README.md`.

**Why both edges pass pf, when the spec says "only Mac 2":** Ext E puts a standby
nginx on Mac 4, and it must reach Backend A on Mac 3 to serve traffic after a
cutover. The rule therefore allows exactly the two edge addresses. A client
probing :3001/:3002 is still FILTERED (`C-isolation/`). Since Mac 4 *is*
Backend B, its own access to :3002 is local and never crosses pf's `in` rule.
