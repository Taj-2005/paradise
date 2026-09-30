#!/usr/bin/env bash
# Inject the rendered mermaid diagrams — and their source — into docs/index.html.
#
#   ./scripts/inline-diagrams.sh
#
# Run after ./scripts/build-diagrams.sh. Together they guarantee the diagram in
# the HTML, the diagram in the markdown, and the .mmd source are the same thing.
#
# Each block is delimited by <!-- DIAGRAM:name --> ... <!-- /DIAGRAM:name -->
# in docs/index.html and is rewritten wholesale, so re-running is idempotent.
#
# Why <img> rather than inlined SVG:
#   * file:// pages cannot fetch(), so a runtime loader would show nothing when
#     someone just double-clicks the HTML;
#   * two inlined mermaid SVGs collide — both declare id="my-svg" and identical
#     arrowhead marker ids, and url(#...) resolves to the first match in the
#     document, so the dark diagram would silently borrow the light one's
#     arrowheads.
# Static <img> sidesteps both, and the files sit next to the page in git.

source "$(dirname "$0")/lib/common.sh"

HTML="$REPO_ROOT/docs/index.html"
D="$REPO_ROOT/docs/diagrams"

hdr "Inlining diagrams into docs/index.html"

declare -a NAMES=("topology" "request-flow")
CAP_topology="Four machines, four roles, one LAN. Numbered arrows follow a single request."
CAP_requestflow="One curl, layer by layer: DNS, TCP, TLS, HTTP, and the separate upstream leg."

for name in "${NAMES[@]}"; do
  for f in "$D/$name-light.svg" "$D/$name-dark.svg" "$D/src/$name.mmd"; do
    [[ -f "$f" ]] || die "Missing $f — run ./scripts/build-diagrams.sh first"
  done
done

python3 - "$HTML" "$D" <<'PY'
import html, re, sys
htmlpath, dpath = sys.argv[1], sys.argv[2]

CAPS = {
  "topology": ("Network topology",
               "Four machines, four roles, one LAN. Numbered arrows follow a single request."),
  "request-flow": ("Request flow",
               "One curl, layer by layer: DNS, TCP, TLS, HTTP, and the separate upstream leg."),
}

doc = open(htmlpath, encoding="utf-8").read()

for name, (title, caption) in CAPS.items():
    mmd = open(f"{dpath}/src/{name}.mmd", encoding="utf-8").read().strip()
    block = f'''<!-- DIAGRAM:{name} -->
<figure>
  <img class="dia lt" src="diagrams/{name}-light.svg" alt="{html.escape(title)} — {html.escape(caption)}">
  <img class="dia dk" src="diagrams/{name}-dark.svg"  alt="{html.escape(title)} — {html.escape(caption)}">
  <figcaption>{html.escape(caption)}
    &nbsp;·&nbsp; <a href="diagrams/src/{name}.mmd">.mmd</a>
  </figcaption>
  <details class="mmdsrc">
    <summary>Mermaid source — {html.escape(title.lower())}</summary>
    <div class="body">
      <div class="codewrap"><pre><code>{html.escape(mmd)}</code></pre></div>
    </div>
  </details>
</figure>
<!-- /DIAGRAM:{name} -->'''

    pattern = re.compile(
        r"<!-- DIAGRAM:" + re.escape(name) + r" -->.*?<!-- /DIAGRAM:" + re.escape(name) + r" -->",
        re.S)
    if not pattern.search(doc):
        sys.exit(f"marker <!-- DIAGRAM:{name} --> not found in {htmlpath}")
    doc = pattern.sub(lambda _: block, doc)
    print(f"  {name}: {len(mmd)} chars of mermaid source + 2 image refs")

open(htmlpath, "w", encoding="utf-8").write(doc)
PY

ok "docs/index.html updated"
echo
