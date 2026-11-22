#!/usr/bin/env bash
# [any]  Inject the Phase 2 diagrams (+ their mermaid source) into docs/index.html.
#
# Same block format as Phase 1's scripts/inline-diagrams.sh, but only touches the
# Phase 2 markers  <!-- DIAGRAM:p2-… --> … <!-- /DIAGRAM:p2-… -->,  so the two
# scripts can run in any order without overwriting each other. Idempotent.

source "$(dirname "$0")/lib/p2common.sh"

HTML="$REPO_ROOT/docs/index.html"
D="$REPO_ROOT/docs/diagrams/phase2"

hdr "Inlining Phase 2 diagrams into docs/index.html"

for name in p2-topology p2-dns-failover p2-ttl-cutover p2-ha-failover; do
  for f in "$D/$name-light.svg" "$D/$name-dark.svg" "$D/src/$name.mmd"; do
    [[ -f "$f" ]] || die "Missing ${f#"$REPO_ROOT"/} — run ./scripts/phase2/build-diagrams.sh first"
  done
done

python3 - "$HTML" "$D" <<'PY'
import html, re, sys
htmlpath, dpath = sys.argv[1], sys.argv[2]

CAPS = {
  "p2-topology":     ("Phase 2 topology",
                      "Same four Macs. Dashed = added in Phase 2: backup DNS, standby edge, pf boundary."),
  "p2-dns-failover": ("Backup DNS failover",
                      "Ext A — the primary stops answering, the client falls through to the backup, the service carries on."),
  "p2-ttl-cutover":  ("TTL and DNS cutover",
                      "Ext B + E — the server changes at once; the OS cache keeps the old edge until the TTL expires."),
  "p2-ha-failover":  ("HA failover at the edge",
                      "Ext D — a failed connect marks A down and the same request is retried on B; A rejoins after fail_timeout."),
}

doc = open(htmlpath, encoding="utf-8").read()
for name, (title, caption) in CAPS.items():
    mmd = open(f"{dpath}/src/{name}.mmd", encoding="utf-8").read().strip()
    block = f'''<!-- DIAGRAM:{name} -->
<figure>
  <img class="dia dia-{name} lt" src="diagrams/phase2/{name}-light.svg" alt="{html.escape(title)} — {html.escape(caption)}">
  <img class="dia dia-{name} dk" src="diagrams/phase2/{name}-dark.svg"  alt="{html.escape(title)} — {html.escape(caption)}">
  <figcaption>{html.escape(caption)}
    &nbsp;·&nbsp; <a href="diagrams/phase2/src/{name}.mmd">.mmd</a>
  </figcaption>
  <details class="mmdsrc">
    <summary>Mermaid source — {html.escape(title.lower())}</summary>
    <div class="body">
      <div class="codewrap"><pre><code>{html.escape(mmd)}</code></pre></div>
    </div>
  </details>
</figure>
<!-- /DIAGRAM:{name} -->'''
    pattern = re.compile(r"<!-- DIAGRAM:" + re.escape(name) + r" -->.*?<!-- /DIAGRAM:" + re.escape(name) + r" -->", re.S)
    if not pattern.search(doc):
        sys.exit(f"marker <!-- DIAGRAM:{name} --> not found in {htmlpath}")
    doc = pattern.sub(lambda _: block, doc)
    print(f"  {name}: {len(mmd)} chars of mermaid source + 2 image refs")
open(htmlpath, "w", encoding="utf-8").write(doc)
PY

ok "docs/index.html updated (Phase 2 markers only)"
