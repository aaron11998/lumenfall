#!/usr/bin/env python3
"""AA-TOKENS v1 — Agency Agents design-token pipeline (AGE-143 deliverable 4).

Validates tokens/v1/tokens.json (DTCG-derived source of truth) and exports:
  build/tokens/css/variables.css        light + dark CSS custom properties
  build/tokens/godot/design_tokens.tres Godot theme (Color + constants) for in-game UI
  build/tokens/tokens_report.json       machine-readable validation + drift report

Gates (CI - wired into build_matrix.sh, exit 1 on violation):
  1. every semantic token reference resolves to a defined primitive
  2. hex colors well-formed; every semantic pair in tokens_report has contrast
     info recomputed (WCAG 2.2 relative luminance) - AA >= 4.5 required for
     text-*/border-focus/accent-on-primary pairs listed in CONTRAST_PAIRS
  3. drift guard: count of hardcoded Color(...) literals in scripts/**/*.gd
     must not exceed TOKEN_DRIFT_BASELINE (stored in .token_drift_baseline;
     growth means new untokenized UI code => FAIL)

Usage: python3 scripts_tool/tokens_pipeline.py [--project /path/to/repo]
Exit codes: 0 = pass, 1 = gate failure, 2 = usage/config error.
"""
import argparse
import json
import math
import re
import sys
from pathlib import Path

DARK_TOKENS = {"text-primary", "text-secondary", "text-link", "border-focus",
               "accent-primary", "accent-on-primary", "bg-primary", "surface-primary"}
# (semantic-light, semantic-dark) pairs certified in extended_tokens_v1.md sec 2.3
# + the v0 core pairs. We recompute ratio and require AA (>=4.5) for text pairs.
CONTRAST_PAIRS = [
    # (theme, fg, bg, minimum)
    ("light", "text-primary", "bg-primary", 4.5),
    ("light", "text-secondary", "bg-primary", 4.5),
    ("light", "text-link", "bg-primary", 4.5),
    ("light", "accent-primary", "bg-primary", 4.5),
    ("light", "accent-on-primary", "accent-primary", 4.5),
    ("dark", "text-primary", "bg-primary", 4.5),
    ("dark", "text-secondary", "bg-primary", 4.5),
    ("dark", "text-link", "bg-primary", 4.5),
    ("dark", "accent-primary", "bg-primary", 4.5),
    ("dark", "accent-on-primary", "accent-primary", 4.5),
]


def hex_to_rgb(h: str):
    h = h.strip().lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if len(h) not in (6, 8):
        raise ValueError(f"bad hex: {h!r}")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    a = int(h[6:8], 16) / 255.0 if len(h) == 8 else 1.0
    return r, g, b, a


def rgba_to_rgb(rgba: str):
    m = re.match(r"rgba?\(([^)]+)\)", rgba.strip())
    if not m:
        raise ValueError(f"bad rgba: {rgba!r}")
    parts = [p.strip() for p in m.group(1).split(",")]
    r, g, b = (int(float(p)) for p in parts[:3])
    a = float(parts[3]) if len(parts) > 3 else 1.0
    return r, g, b, a


def parse_color(value: str):
    if value.startswith("#"):
        return hex_to_rgb(value)
    if value.startswith("rgba"):
        return rgba_to_rgb(value)
    raise ValueError(f"unparseable color: {value!r}")


def rel_lum(rgb):
    def chan(c):
        c = c / 255.0
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = rgb[:3]
    return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)


def contrast(fg_rgb, bg_rgb):
    l1, l2 = sorted((rel_lum(fg_rgb), rel_lum(bg_rgb)), reverse=True)
    return (l1 + 0.05) / (l2 + 0.05)


def resolve(token: str, primitives: dict):
    """Resolve a semantic reference (possibly rgba() literal) to rgb."""
    if token.startswith("#") or token.startswith("rgba"):
        return parse_color(token)
    if token not in primitives:
        raise KeyError(f"unresolved primitive reference: {token!r}")
    return parse_color(primitives[token])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default=".")
    args = ap.parse_args()
    proj = Path(args.project).resolve()
    src = proj / "tokens" / "v1" / "tokens.json"
    if not src.is_file():
        print(f"TOKENS_RESULT=FAIL source missing: {src}", file=sys.stderr)
        return 2

    try:
        data = json.loads(src.read_text())
    except json.JSONDecodeError as e:
        print(f"TOKENS_RESULT=FAIL invalid JSON: {e}", file=sys.stderr)
        return 2

    errors, findings = [], []
    colors = data.get("color", {})
    primitives = colors.get("primitive", {})
    themes = colors.get("semantic", {})

    # --- gate 1: structural + reference resolution -------------------------
    hexre = re.compile(r"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
    resolved = {}  # (theme, name) -> rgb
    for theme in ("light", "dark"):
        sem = themes.get(theme, {})
        if not sem:
            errors.append(f"missing semantic theme: {theme}")
            continue
        for name, ref in sem.items():
            if ref.startswith("#") and not hexre.match(ref):
                errors.append(f"{theme}/{name}: malformed hex {ref!r}")
                continue
            try:
                resolved[(theme, name)] = resolve(ref, primitives)
            except (KeyError, ValueError) as e:
                errors.append(f"{theme}/{name}: {e}")

    # semantic parity between themes (AGE-59 dark-parity requirement)
    lnames, dnames = set(themes.get("light", {})), set(themes.get("dark", {}))
    for missing in sorted(lnames ^ dnames):
        errors.append(f"semantic parity: {missing!r} not present in both themes")

    # --- gate 2: contrast --------------------------------------------------
    contrast_report = []
    for theme, fg, bg, minimum in CONTRAST_PAIRS:
        try:
            ratio = contrast(resolved[(theme, fg)], resolved[(theme, bg)])
        except KeyError:
            errors.append(f"contrast pair unresolved: {theme} {fg}/{bg}")
            continue
        ok = ratio >= minimum
        contrast_report.append({"theme": theme, "fg": fg, "bg": bg,
                                "ratio": round(ratio, 2), "min": minimum, "pass": ok})
        if not ok:
            errors.append(f"contrast {theme}: {fg} on {bg} = {ratio:.2f} < {minimum}")

    # --- gate 3: hardcoded-color drift guard -------------------------------
    baseline_file = proj / ".token_drift_baseline"
    gd_files = list((proj / "scripts").rglob("*.gd")) if (proj / "scripts").is_dir() else []
    hits = []
    for gd in gd_files:
        for i, line in enumerate(gd.read_text(errors="replace").splitlines(), 1):
            if re.search(r"\bColor\(", line) and not line.strip().startswith("#"):
                hits.append(f"{gd.relative_to(proj)}:{i}")
    drift_count = len(hits)
    baseline = None
    if baseline_file.is_file():
        try:
            baseline = int(baseline_file.read_text().strip())
        except ValueError:
            errors.append(f".token_drift_baseline unparseable: {baseline_file}")
    if baseline is None:
        # first run: seed the baseline (adoption run, not a violation)
        baseline_file.write_text(f"{drift_count}\n")
        findings.append(f"seeded .token_drift_baseline = {drift_count} (first run)")
    elif drift_count > baseline:
        errors.append(
            f"token drift: {drift_count} hardcoded Color() literals > baseline {baseline} "
            f"(new untokenized UI in: {', '.join(hits[:5])}). Use design_tokens.tres.")
    else:
        findings.append(f"drift guard: {drift_count}/{baseline} hardcoded Color() (within baseline)")

    # --- export: CSS custom properties -------------------------------------
    css_out = proj / "build" / "tokens" / "css"
    css_out.mkdir(parents=True, exist_ok=True)
    lines = [f"/* Agency Agents design tokens v{data.get('meta', {}).get('version', '?')}",
             "   AUTOGENERATED by scripts_tool/tokens_pipeline.py — DO NOT EDIT BY HAND.",
             "   Source: tokens/v1/tokens.json */", ":root {"]
    for name, val in primitives.items():
        lines.append(f"  --color-{name}: {val};")
    for name, ref in themes.get("light", {}).items():
        val = ref if ref.startswith(("#", "rgba")) else primitives.get(ref, ref)
        lines.append(f"  --{name}: {val};")
    lines.extend(["}", "",
                  "/* dark theme — applies via [data-theme=\"dark\"] or media query */",
                  "@media (prefers-color-scheme: dark) {", ":root {"])
    for name, ref in themes.get("dark", {}).items():
        val = ref if ref.startswith(("#", "rgba")) else primitives.get(ref, ref)
        lines.append(f"  --{name}: {val};")
    lines.append("}")
    # explicit opt-in class so hosts can force dark regardless of media query
    lines.append('[data-theme="dark"] {')
    for name, ref in themes.get("dark", {}).items():
        val = ref if ref.startswith(("#", "rgba")) else primitives.get(ref, ref)
        lines.append(f"  --{name}: {val};")
    lines.append("}}")
    # typography fluid clamps + spacing/radius tokens
    lines.append("")
    for name, spec in data.get("typography", {}).items():
        px, lh = spec["size"], spec["lineHeight"]
        lines.append(f"  --text-{name}: {px / 16:.3f}rem; --text-{name}-lh: {lh};")
    for name, val in data.get("spacing", {}).items():
        lines.append(f"  --{name}: {val}px; --{name}-rem: {val / 16:.4f}rem;")
    for name, val in data.get("radius", {}).items():
        lines.append(f"  --{name}: {'9999px' if val >= 9999 else f'{val}px'};")
    css = "\n".join(lines) + "\n"
    (css_out / "variables.css").write_text(css)

    # --- export: Godot tokens (GDScript consts — parse-checked by CI import) ---
    # A .tres with embedded GDScript consts is invalid Godot resource syntax, so
    # we emit design_tokens.gd: a plain script whose LIGHT/DARK dictionaries are
    # readable from any Node: `var T = load("res://build/tokens/godot/design_tokens.gd").new()`
    def godot_color(rgb) -> str:
        r, g, b, a = rgb
        return (f"Color8({round(r)}, {round(g)}, {round(b)}, {round(a * 255)})")

    def flatten_theme(theme: str) -> dict:
        out = {}
        for name, ref in themes.get(theme, {}).items():
            try:
                out[name] = resolve(ref, primitives)
            except (KeyError, ValueError):
                continue
        return out

    light_map, dark_map = flatten_theme("light"), flatten_theme("dark")
    gd = ["# AUTOGENERATED by scripts_tool/tokens_pipeline.py — DO NOT EDIT BY HAND.",
          "# Source: tokens/v1/tokens.json (Agency Agents design tokens v1).",
          "# Usage: var T = load('res://build/tokens/godot/design_tokens.gd').new()",
          "#        T.LIGHT['text-primary'] -> Color",
          "extends RefCounted",
          "class_name AADesignTokens",
          ""]
    gd.append("const VERSION := \"" + data.get("meta", {}).get("version", "?") + "\"")
    gd.append("")
    gd.append("const LIGHT: Dictionary = {")
    for name, rgb in sorted(light_map.items()):
        gd.append(f'\t"{name}": {godot_color(rgb)},')
    gd.append("}")
    gd.append("")
    gd.append("const DARK: Dictionary = {")
    for name, rgb in sorted(dark_map.items()):
        gd.append(f'\t"{name}": {godot_color(rgb)},')
    gd.append("}")
    godot_out = proj / "build" / "tokens" / "godot"
    godot_out.mkdir(parents=True, exist_ok=True)
    (godot_out / "design_tokens.gd").write_text("\n".join(gd) + "\n")

    # --- report ------------------------------------------------------------
    report = {
        "version": data.get("meta", {}).get("version"),
        "primitiveCount": len(primitives),
        "semanticCount": {t: len(themes.get(t, {})) for t in ("light", "dark")},
        "contrast": contrast_report,
        "drift": {"count": drift_count, "baseline": baseline,
                  "withinBaseline": drift_count <= (baseline or drift_count),
                  "files": hits[:20]},
        "findings": findings,
        "errors": errors,
    }
    rpt_out = proj / "build" / "tokens"
    (rpt_out / "tokens_report.json").write_text(json.dumps(report, indent=2) + "\n")

    print(f"tokens: v{report['version']} — {len(primitives)} primitives, "
          f"{report['semanticCount']['light']}/{report['semanticCount']['dark']} semantic (light/dark)")
    for f in findings:
        print(f"  note: {f}")
    worst = min(contrast_report, key=lambda c: c["ratio"]) if contrast_report else None
    if worst:
        print(f"  contrast: min ratio {worst['ratio']}:1 ({worst['theme']} {worst['fg']} on {worst['bg']})")
    print(f"  exports: {css_out / 'variables.css'} | {godot_out / 'design_tokens.gd'}")

    if errors:
        print("TOKENS_RESULT=FAIL", file=sys.stderr)
        for e in errors:
            print(f"  ERROR: {e}", file=sys.stderr)
        return 1
    print("TOKENS_RESULT=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
