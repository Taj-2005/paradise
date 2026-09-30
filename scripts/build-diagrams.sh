#!/usr/bin/env bash
# Render docs/diagrams/*.mmd to SVG and PNG, in light and dark variants.
#
#   ./scripts/build-diagrams.sh          # all diagrams
#   ./scripts/build-diagrams.sh topology # just one
#
# The rendered files ARE COMMITTED, so nobody needs mermaid-cli to read the
# docs — you only need this script if you edit a .mmd.
#
# What it does beyond calling mmdc:
#
#  1. Two variants per diagram. The .mmd files carry the light palette inline
#     so they stay valid, previewable mermaid in any editor. The dark variant
#     is produced by swapping colours through theme/palette.json in a single
#     pass, plus a dark themeVariables config.
#
#  2. Strips embedded fonts. mermaid-cli base64-embeds four web fonts into
#     every SVG, which is ~160 KB of the ~200 KB output. We render with a
#     system font stack, so those are dead weight — removing them takes each
#     SVG to roughly a quarter of its size, and the text still renders
#     identically because the stack resolves natively on macOS.

source "$(dirname "$0")/lib/common.sh"

D="$REPO_ROOT/docs/diagrams"       # rendered images live here
SRC="$D/src"                       # .mmd sources + theme config live here
THEME="$SRC/theme"
ONLY="${1:-}"

# ── Locate mmdc ─────────────────────────────────────────────────────────────
if command -v mmdc >/dev/null 2>&1; then
  MMDC=(mmdc)
elif [[ -x "$REPO_ROOT/node_modules/.bin/mmdc" ]]; then
  MMDC=("$REPO_ROOT/node_modules/.bin/mmdc")
else
  warn "mermaid-cli not found; falling back to npx (first run downloads Chromium)."
  warn "To install it locally instead:  npm i -D @mermaid-js/mermaid-cli"
  MMDC=(npx -y -p @mermaid-js/mermaid-cli mmdc)
fi

hdr "Rendering mermaid diagrams"

# ── Strip the base64 @font-face blocks mermaid-cli embeds ───────────────────
strip_fonts() {
  python3 - "$1" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
before = len(s)

# Remove every @font-face rule (each carries a base64 payload).
s = re.sub(r'@font-face\s*\{[^}]*\}', '', s)

# Point any remaining font-family at a system stack so text still renders.
stack = ("ui-sans-serif,system-ui,-apple-system,'Segoe UI',"
         "Helvetica,Arial,sans-serif")
s = re.sub(r'font-family:\s*"?[^;"}]*"?\s*;', f'font-family:{stack};', s)

# Collapse the whitespace the removals leave behind.
s = re.sub(r'\n\s*\n+', '\n', s)

open(p, "w", encoding="utf-8").write(s)
print(f"{before//1024} KB -> {len(s)//1024} KB", end="")
PY
}

# ── Produce the dark-variant source ─────────────────────────────────────────
make_dark_src() {
  python3 - "$1" "$2" "$THEME/palette.json" <<'PY'
import json, re, sys
src, dst, pal = sys.argv[1], sys.argv[2], sys.argv[3]
m = {k.lower(): v for k, v in json.load(open(pal)).items() if k.startswith("#")}
s = open(src, encoding="utf-8").read()
# Single pass over an alternation, so no swapped colour is ever re-swapped.
pattern = re.compile("|".join(re.escape(k) for k in sorted(m, key=len, reverse=True)),
                     re.IGNORECASE)
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
    if [[ "$variant" == light ]]; then in="$src"; else in="$dark_src"; fi

    # Explicit opaque canvas per variant. With -b transparent the SVG looks
    # correct inside index.html (which paints its own background) and wrong
    # everywhere else — opened on its own, or on GitHub's dark theme, whatever
    # is behind it shows through.
    if [[ "$variant" == light ]]; then bg="#ffffff"; else bg="#0b1220"; fi

    svg="$D/$name-$variant.svg"
    "${MMDC[@]}" -i "$in" -o "$svg" -c "$THEME/$variant.json" -b "$bg" \
      --quiet >/dev/null 2>&1 || die "mmdc failed on $name ($variant)"
    saved="$(strip_fonts "$svg")"
    ok "$name-$variant.svg    $saved"

    # PNG is opt-in. Nothing in the docs renders from it — every page uses the
    # SVG — and the raster copies are ~7x the bytes. Generate them only when
    # you actually need one for a slide deck or the Phase 2 report:
    #     WITH_PNG=1 make diagrams
    if [[ "${WITH_PNG:-0}" == "1" ]]; then
      png="$D/$name-$variant.png"
      "${MMDC[@]}" -i "$in" -o "$png" -c "$THEME/$variant.json" \
        -b "$bg" \
        -s 2 --quiet >/dev/null 2>&1 || die "mmdc failed on $name ($variant, png)"
      ok "$name-$variant.png    $(( $(wc -c < "$png") / 1024 )) KB"
    fi
  done

  rm -f "$dark_src"
  count=$((count + 1))
done

(( count > 0 )) || die "Nothing matched '$ONLY'"

echo
info "Rendered $count diagram(s) x 2 themes.${WITH_PNG:+ (+PNG)}"
[[ "${WITH_PNG:-0}" == "1" ]] || info "PNG skipped — use WITH_PNG=1 make diagrams if you need raster copies."
info "Now refresh the inlined copies in docs/index.html:"
info "    ./scripts/inline-diagrams.sh"
echo
