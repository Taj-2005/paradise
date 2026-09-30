# Diagrams

Rendered SVGs live here. Their **sources live in [`src/`](src/)** — edit those,
never the output.

```
diagrams/
├── topology-light.svg       ← rendered by index.html and the markdown docs
├── topology-dark.svg
├── request-flow-light.svg
├── request-flow-dark.svg
└── src/
    ├── topology.mmd         ← mermaid flowchart
    ├── request-flow.mmd     ← mermaid sequence diagram
    └── theme/
        ├── light.json       ← mermaid theme config
        ├── dark.json
        └── palette.json     ← light → dark colour map
```

## Editing a diagram

```bash
$EDITOR docs/diagrams/src/topology.mmd
make diagrams
```

`make diagrams` runs two idempotent scripts:

| Script | Does |
|---|---|
| `scripts/build-diagrams.sh` | renders each `.mmd` to SVG, light and dark |
| `scripts/inline-diagrams.sh` | refreshes the image refs and source blocks in `docs/index.html` |

The rendered SVGs **are committed**, so nobody needs mermaid-cli just to read
the docs — only to change a diagram.

## Why two SVGs per diagram

The docs are theme-aware. `docs/index.html` swaps light and dark with
`prefers-color-scheme`; the markdown uses `<picture>`, which is the one
theme-swap mechanism GitHub honours.

## Need a PNG?

Nothing in the docs renders from raster — every page uses the SVG, which stays
sharp at any zoom and is about a seventh of the bytes. If you want PNGs for a
slide deck or the Phase 2 report:

```bash
WITH_PNG=1 make diagrams
```

That writes `*-light.png` / `*-dark.png` at 2× alongside the SVGs. They are
gitignored, so they will not come back into the repo.

## How the dark variant is produced

The `.mmd` files carry the **light** palette inline, so they remain valid,
previewable mermaid in any editor or mermaid playground. `build-diagrams.sh`
generates the dark variant by swapping colours through
[`src/theme/palette.json`](src/theme/palette.json) in a single pass, then
renders with `src/theme/dark.json`.

One source of truth, without making the `.mmd` unreadable to other tools.
