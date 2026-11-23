#!/usr/bin/env bash
# [any]  Render docs/diagrams/phase2/src/*.mmd -> docs/diagrams/phase2/*-{light,dark}.svg
#
#   ./scripts/phase2/build-diagrams.sh               # all Phase 2 diagrams
#   ./scripts/phase2/build-diagrams.sh p2-topology   # just one
#
# Same pipeline as Phase 1's scripts/build-diagrams.sh, and the SAME theme files
# (docs/diagrams/src/theme/{light,dark,palette}.json), so both phases render
# identically. A companion script rather than a call into Phase 1's because that
# one hardcodes docs/diagrams/src — Phase 1 stays untouched.
#
# Rendered SVGs are committed: nobody needs mermaid-cli just to read the docs.

source "$(dirname "$0")/lib/p2common.sh"

D="$REPO_ROOT/docs/diagrams/phase2"
SRC="$D/src"
THEME="$REPO_ROOT/docs/diagrams/src/theme"     # reused from Phase 1
ONLY="${1:-}"

if command -v mmdc >/dev/null 2>&1; then MMDC=(mmdc)
elif [[ -x "$REPO_ROOT/node_modules/.bin/mmdc" ]]; then MMDC=("$REPO_ROOT/node_modules/.bin/mmdc")
else
  warn "mermaid-cli not found; using npx (first run downloads Chromium)."
  MMDC=(npx -y -p @mermaid-js/mermaid-cli mmdc)
fi

hdr "Rendering Phase 2 diagrams"

# Identical to Phase 1: drop the ~160 KB of base64 fonts mmdc embeds and point
# text at the system stack.
strip_fonts() {
  python3 - "$1" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read(); before = len(s)
s = re.sub(r'@font-face\s*\{[^}]*\}', '', s)
stack = "ui-sans-serif,system-ui,-apple-system,'Segoe UI',Helvetica,Arial,sans-serif"
s = re.sub(r'font-family:\s*"?[^;"}]*"?\s*;', f'font-family:{stack};', s)
s = re.sub(r'\n\s*\n+', '\n', s)
open(p, "w", encoding="utf-8").write(s)
print(f"{before//1024} KB -> {len(s)//1024} KB", end="")
PY
}

# Identical to Phase 1: single-pass light->dark colour swap via palette.json.
make_dark_src() {
  python3 - "$1" "$2" "$THEME/palette.json" <<'PY'
import json, re, sys
src, dst, pal = sys.argv[1], sys.argv[2], sys.argv[3]
m = {k.lower(): v for k, v in json.load(open(pal)).items() if k.startswith("#")}
s = open(src, encoding="utf-8").read()
pattern = re.compile("|".join(re.escape(k) for k in sorted(m, key=len, reverse=True)), re.IGNORECASE)
open(dst, "w", encoding="utf-8").write(pattern.sub(lambda x: m[x.group(0).lower()], s))
PY
}

count=0
for src in "$SRC"/*.mmd; do
  [[ -e "$src" ]] || die "No .mmd files in $SRC"
  name="$(basename "$src" .mmd)"
  [[ -n "$ONLY" && "$name" != "$ONLY" ]] && continue
  step "$name"
  dark_src="$(mktemp -t "${name}-dark").mmd"
  make_dark_src "$src" "$dark_src"
  for variant in light dark; do
    if [[ "$variant" == light ]]; then in="$src"; bg="#ffffff"; else in="$dark_src"; bg="#0b1220"; fi
    svg="$D/$name-$variant.svg"
    "${MMDC[@]}" -i "$in" -o "$svg" -c "$THEME/$variant.json" -b "$bg" --quiet >/dev/null 2>&1 \
      || die "mmdc failed on $name ($variant) — check the .mmd syntax at https://mermaid.live"
    ok "$name-$variant.svg    $(strip_fonts "$svg")"
  done
  rm -f "$dark_src"
  count=$((count + 1))
done
(( count > 0 )) || die "Nothing matched '$ONLY'"

echo
info "Rendered $count diagram(s) x 2 themes. Now refresh docs/index.html:"
info "    ./scripts/phase2/inline-diagrams.sh      (or: make p2-diagrams does both)"
