# Phase 2 — Harden, Recover & Troubleshoot

Phase 2 extends the Phase 1 network. **Nothing is rebuilt.** Every Phase 1
template, script and `.env` value is reused, and Phase 2 only adds files. The
one Phase 1 file with a code change is the root `Makefile`, which gains a
five-line delegation to `scripts/phase2/phase2.mk`.

| Where | What |
|---|---|
| `scripts/phase2/` | runnable scripts, the shared lib (`lib/p2common.sh`) and `phase2.mk` |
| `infra/phase2/` | pf rule template, `.env.phase2.example`, `certs/` and `build/` (both gitignored) |
| `docs/phase2/` | this runbook, [architecture](architecture.md) and the [final report](report.md) |
| `docs/diagrams/phase2/` | Phase 2 diagrams: topology, DNS failover, TTL cutover, HA failover (`make p2-diagrams`) |
| `evidence/phase2/` | everything the demo and verify scripts write, see [its README](../../evidence/phase2/README.md) |

Run `make p2` for the full target list.

## How Phase 2 reuses Phase 1

Phase 2 renders the **same Phase 1 templates** with a few values overridden.
It does not keep copies of them.

| Profile | Template (Phase 1) | Overrides |
|---|---|---|
| Primary DNS (Ext B) | `infra/mac1-dns/dnsmasq.conf.template` | `DNS_TTL=30`, `EDGE_IP=<current target>` |
| Backup DNS (Ext A) | same | `DNS_IP=<backup>`, `DNS_TTL=30`, `EDGE_IP=<current target>` |
| Standby edge (Ext E) | `infra/mac2-edge/nginx/*.template` | `EDGE_IP=<standby>`, `CERT_DIR=infra/phase2/certs` |
| Isolation (Ext C) | `infra/phase2/pf/backend-isolation.pf.tpl` (new) | `BACKEND_PORT`, allow-list = both edges |

The pf template is `.tpl`, not `.template`, on purpose. Phase 1's
`render-configs.sh` renders every `*.template` under `infra/`. It would abort on
`{{BACKEND_PORT}}`, and that would break `make dns` and `make edge`.

## Machine placement

| Machine | Phase 1 role | Phase 2 adds |
|---|---|---|
| Mac 1 | DNS (primary) + client | TTL 30 profile; it is the client for the Ext C, D and F demos |
| Mac 2 | Edge (nginx) | `p2-health-watch` (read-only) |
| Mac 3 | Backend A + client | pf isolation on :3001; the client for the Ext A and B + E demos (it is neither DNS server nor an edge) |
| Mac 4 | Backend B + client | **Backup DNS** (dnsmasq) + **standby edge** (nginx) + pf isolation on :3002 |

Mac 4 hosts three services on different ports (`:3002`, `:53`, `:80/:443`). The
trade-off is shared fate, see [architecture.md](architecture.md#shared-fate-on-mac-4).

## Team roles (Phase 2)

| Member | Phase 2 role | Owns |
|---|---|---|
| Nipun ([@nipun1803](https://github.com/nipun1803)) | Primary DNS and TTL (Ext B), documentation | `install-primary-dns`, `ttl-watch`, `flush-dns`, `client-dns`, `dns-service`; runbook, report, setup guide |
| Anushka ([@anu-ushka](https://github.com/anu-ushka)) | Edge cutover and HA failover (Ext D, E) | `install-standby-edge`, `dns-cutover`, `health-watch`, `ha-demo`; `architecture.md` |
| Tajuddin Shaik ([@Taj-2005](https://github.com/Taj-2005)) | Backup DNS (Ext A), isolation (Ext C), tooling | `install-backup-dns`, `demo-dns-failover`, `install-isolation`, `isolation-test`, `p2common.sh`, `phase2.mk`, pf template |
| Omkar Hadole ([@omkar-hadole](https://github.com/omkar-hadole)) | Troubleshooting (Ext F), verification, evidence | `diagnose`, `inject-fault`, `rollback`, `status-phase2`, `test-phase2`, `verify-phase2`, `collect-evidence`, `evidence/phase2` |

To move a role, set `BACKUP_DNS_IP` or `STANDBY_EDGE_IP` in
`infra/phase2/.env.phase2`. Everything follows from those values.

---

## Setup (once, in this order)

Phase 1 must already pass `make verify`. Starting from a **fresh clone**? Follow
the combined Phase 1 → Phase 2 run order in
[`docs/index.html` → Start here](../index.html#fresh), with one tab per Mac.

```bash
# all Macs — pull the repo; .env from Phase 1 is reused as-is
make p2-test                         # offline: syntax, rendering, Phase 1 untouched

# Mac 1
make p2-primary-dns                  # Ext B: TTL 0 -> 30, Phase 1 config backed up

# Mac 4
make p2-backup-dns                   # Ext A: second dnsmasq, same records
scp …/infra/mac2-edge/certs/{app.paradise.test.crt,app.paradise.test.key,rootCA.pem} \
    <mac4>:<repo>/infra/phase2/certs/   # run on Mac 2
make p2-standby-edge                 # Ext E: standby nginx (no client uses it yet)
make p2-isolate                      # Ext C: pf on :3002

# Mac 3
make p2-isolate                      # Ext C: pf on :3001

# clients (Mac 1, Mac 3, Mac 4)
make p2-client-dns                   # resolvers = Mac 1, then Mac 4

# any client — acceptance
make p2-verify
```

## Demonstrations (spec §8 step 9 and Ext A–F)

| Ext | Where | Command | What to point at |
|---|---|---|---|
| A | client (Mac 3) | `make p2-demo-dns-failover` | it prompts you to run `make p2-dns-stop` on Mac 1, then `dig` shows `SERVER: <Mac 4>` while curl still returns 200 |
| B | client (Mac 3) | `make p2-ttl-watch` while Mac 1 and Mac 4 run `make p2-cutover TO=standby` | the **SERVER** column flips at once; **OS-CACHE** and **CURL→IP** stay on the old edge for up to 30 s; `make p2-flush` flips them immediately |
| C | Mac 2, then Mac 1 | `make p2-isolation-test` | edge: OPEN; client: FILTERED (timeout, not refused); both still 200 through the edge |
| D | Mac 2 + client | `make p2-health-watch` and `make p2-ha-demo` | Ctrl-C Backend A at about 10 s → B only with zero errors; `make backend-a` at about 35 s → A rejoins |
| E | Mac 1 + Mac 4, client (Mac 3) | `make p2-cutover TO=standby` on both DNS Macs, `make p2-ttl-watch` on the client | `X-Edge` changes from `nginx@<Mac 2>` to `nginx@<Mac 4>` once the TTL expires |
| F | client | `make p2-diagnose` | the first failing layer is the verdict |

Cut back afterwards with `make p2-cutover TO=primary` on both DNS Macs.

### Practising Extension F

One teammate injects a fault and another diagnoses it **without being told which**:

```bash
make p2-fault F=list                 # see every fault and where it runs
make p2-fault F=hosts-override       # on a client
make p2-diagnose                     # the diagnoser, on that client
make p2-fault-undo F=hosts-override
```

| Fault | Layer | What the diagnoser should say |
|---|---|---|
| `hosts-override` | DNS (local) | `/etc/hosts` overrides the name; dig and the OS disagree |
| `client-dns-wrong` | DNS (resolver) | resolver list lacks the team DNS; NXDOMAIN |
| `dns-wrong-ip` | DNS (data) | resolves to an IP that is not an edge |
| `dns-down` | DNS (service) | nothing fails while the backup answers; that is Ext A working |
| `edge-down` | Transport | connection **refused** on :443 |
| `edge-filtered` | Transport | connection **timed out** on :443 |
| `backend-filtered` (both Macs) | Application | DNS, TCP and TLS pass; HTTP 502/504 from the edge |

## Rollback

Every change has an exact undo. `make p2-rollback` reverts everything on *this*
machine, or pass `WHAT=` to revert one piece:

| `WHAT=` | Machine | Effect |
|---|---|---|
| `primary-dns` | Mac 1 | re-runs the **Phase 1 installer** (TTL back to 0) |
| `backup-dns` | Mac 4 | stops dnsmasq and restores its prior config |
| `client-dns` | clients | restores the resolver list saved before Phase 2 |
| `isolation` | Mac 3/4 | flushes the pf anchor and releases our pf token |
| `standby-edge` | Mac 4 | stops nginx and restores its prior config |
| `cutover` | DNS Macs | records point back at Mac 2 |
| `faults` | any | undoes every practice fault injected here |

Backups are taken before the first change: `*.pre-phase2` next to each
Homebrew config, plus a pf snapshot in `infra/phase2/build/state/pf-backup-*/`.
