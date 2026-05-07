# Design Tokens — Reference

The authoritative source is `.missions/scribe-visual-rebuild/design-reference/colors_and_type.css`. This document is a worker-facing summary; when in doubt, open the CSS.

## Color tokens (dark mode is canonical for popover/HUD/toast/menu-bar)

| Token | Value (OKLCH) | Use |
|---|---|---|
| `--bg` | `#000` | Page background, popover body fallback |
| `--bg-subtle` | `oklch(0.16 0 0)` | One-step-up surface |
| `--bg-muted` | `oklch(0.20 0 0)` | Two-step-up surface |
| `--bg-elevated` | `oklch(0.18 0 0)` | Card surface |
| `--fg-1` | `#fff` | Primary text |
| `--fg-2` | `oklch(0.78 0 0)` | Secondary text |
| `--fg-3` | `oklch(0.60 0 0)` | Captions |
| `--fg-4` | `oklch(0.45 0 0)` | Disabled / faint |
| `--border` | `oklch(0.27 0 0)` | Default 1px hairlines |
| `--border-strong` | `oklch(0.36 0 0)` | Hover/focus |
| `--accent` | `oklch(0.50 0.09 255)` | Primary CTA, focus ring |
| `--live-dot` | `oklch(0.62 0.16 35)` | Live recording dot color |
| `--live-dot-glow` | `oklch(0.62 0.16 35 / 0.55)` | Live dot ping shadow |
| `--recording` | `oklch(0.55 0.14 35)` | Recording state color (warm rust) |
| `--success` | `oklch(0.62 0.17 150)` | Success indicator |
| `--warning` | `oklch(0.75 0.15 75)` | Warning indicator |
| `--danger` | `oklch(0.58 0.22 25)` | Danger indicator |

**Conversion to sRGB:** OKLCH→sRGB conversion should preserve perceptual hue/chroma. The existing `DesignSystem.swift` uses Apple's display-p3 colorspace which gives ΔE<2 alignment. New tokens added must use the same approach.

## Typography

| Token | Spec |
|---|---|
| `--font-sans` | Inter Variable (woff2 + ttf bundled in `Fonts/`) |
| Display | clamp(48px, 7vw, 96px), weight 600, tracking -0.04em, leading 1.0 |
| h1 | 48px, weight 600, tracking -0.02em, leading 1.1 |
| h2 | 28px, weight 600, tracking -0.02em, leading 1.25 |
| h3 | 18px, weight 600, tracking -0.02em, leading 1.25 |
| h4 | 16px, weight 600, leading 1.25 |
| Body | 14px, leading 1.65, color `--fg-2` |
| Body small | 13px, leading 1.5 |
| Caption | 12px, color `--fg-3` |
| Eyebrow | 12px, uppercase, tracking 0.06em, weight 500, color `--fg-3` |
| Indicator | 11px, tracking 0.06em, weight 500, mono caps text |

## Spacing scale

`--space-0` = 0
`--space-1` = 2px
`--space-2` = 4px
`--space-3` = 6px
`--space-4` = 8px
`--space-5` = 12px
`--space-6` = 16px
`--space-7` = 20px
`--space-8` = 24px
`--space-9` = 32px
`--space-10` = 40px
`--space-11` = 48px
`--space-12` = 64px
`--space-13` = 80px
`--space-14` = 96px
`--space-15` = 128px

## Radii

`--radius-xs` = 2px / `--radius-sm` = 4px / `--radius-md` = 6px (default) / `--radius-lg` = 8px / `--radius-xl` = 12px / `--radius-2xl` = 16px / `--radius-full` = 9999px

Popover uses 12px (`--radius-xl`); HUD uses 14px (between xl and 2xl); toast uses 12px; settings window uses 12px; buttons use 7px (slightly different from the system tokens — see `.btn` spec).

## Shadows (used sparingly in dark mode; borders carry elevation)

- `--shadow-menu` — popover lift: `0 0 0 0.5px rgba(0,0,0,0.5), 0 24px 60px rgba(0,0,0,0.55), 0 8px 16px rgba(0,0,0,0.35)`.
- HUD: `0 24px 60px rgba(0,0,0,0.55), 0 0 0 0.5px rgba(0,0,0,0.4)`.
- Toast: `0 12px 40px rgba(0,0,0,0.45)`.
- Inner top highlight (popover and HUD): `inset 0 1px 0 rgba(255,255,255,0.06)`.

## Motion

| Token | Value | Use |
|---|---|---|
| `--ease-out` | `cubic-bezier(0.22, 1, 0.36, 1)` | Default |
| `--duration-fast` | 120ms | Hover / press |
| `--duration-base` | 180ms | State transitions |
| `--duration-slow` | 280ms | Slow transitions (rare) |

Continuous animations (allowed only in two places):
- Recording-pane waveform: per-bar `wf-anim` keyframe, 900ms ease-in-out, infinite, with staggered delays.
- Live-dot ping: `live-ping` keyframe, 1.6s `--ease-out`, infinite, expanding rgba shadow.
- Menu-bar bar pulse (during recording): scale-Y 0.7→1.25, 900ms ease-in-out, staggered per bar.

Reduced motion: when `accessibilityDisplayShouldReduceMotion` is true, all three are paused (waveform shows static envelope; live dot is static; bars don't pulse).

## Voice rules (locked)

- Lowercase brand `scribe` in body copy.
- Sentence case for labels and buttons. NEVER Title Case.
- Mono caps text only inside `.indicator` (e.g., `LIVE`, `READY`, `SENT`).
- No emoji.
- Exact copy strings in `AGENTS.md` are non-negotiable.

## Indicator states (the only allowed status pattern)

| State | Color | Animation |
|---|---|---|
| `live` | `--live-dot` (rust) | Ping (expanding shadow) |
| `ready` | `oklch(0.78 0.10 255)` (dark mode) | None |
| `tx` (transcribing) | `oklch(0.78 0 0)` | Dim alternate |
| `sent` | `oklch(0.78 0.11 145)` | None |
| `failed` | `oklch(0.78 0.13 25)` | None |
| `idle` | `oklch(0.55 0 0)` | None |

Workers use the existing `Indicator` view in `DesignSystem.swift` and add states if any are missing.
