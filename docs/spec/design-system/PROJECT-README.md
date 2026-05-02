# Scribe Design System

> **Scribe captures every call from your Mac menu bar and turns it into fuel for your agents.**

A design system for Scribe — a Mac menu bar app that auto-transcribes every call you take and feeds the transcripts into agentic workflows. Built for an audience of developer-operators: people building with Claude, Cursor, n8n, Zapier, custom MCP tools.

---

## Index

| File / Folder | What it is |
|---|---|
| `README.md` | This file. Brand context + content + visual foundations. |
| `colors_and_type.css` | All design tokens (colors, type, spacing, radii, shadows, motion) as CSS variables, plus base element styles. |
| `SKILL.md` | Skill manifest. Lets this design system be loaded into Claude Code as a reusable skill. |
| `assets/` | Logos (mark, wordmark, menu bar icon), brand glyphs. |
| `fonts/` | (Empty — Geist is loaded from Google Fonts CDN. Drop local woff2 here if needed.) |
| `preview/` | Design system tab cards — type specimens, palette swatches, component previews. |
| `ui_kits/marketing/` | Marketing site recreation (hero, install, features, footer). |
| `ui_kits/menubar/` | The Mac menu bar app itself — popover, transcript view, settings. |

---

## Sources

This design system was built from a brief — no codebase, Figma, or screenshots were provided. The aesthetic direction is **Vercel-inspired**: stark monochrome, surgical neutral grays, a single signal-blue accent, Geist as the primary type, no gradients, no decoration, content-first composition.

If you have an existing codebase, Figma, or product screenshots, attach them and we'll iterate the system to match.

---

## Product context

**What Scribe does.** Sits in your Mac menu bar. Detects when you're on a call (Zoom, Meet, FaceTime, Teams, anything). Records system audio + mic, transcribes locally or via API, then exposes the transcript as structured data to your agents — through webhooks, MCP, a local SQLite store, or direct paste into a chat.

**Who it's for.** Developers and operators who already run agents in their workflow. The pitch isn't "another notetaker" — it's a **data source for the agents you already have**. Drafts, follow-ups, CRM updates, notes, all from a click in your menu bar.

**Surfaces.**
1. **Marketing site** — single-page Vercel-style landing. Hero, install, what-it-feeds, pricing, footer.
2. **Mac menu bar app** — small SwiftUI-style popover that opens from the menu bar icon. Lists recent calls, lets you tag transcripts, drag them out, fire webhooks.

---

## Content fundamentals

The voice is **terse, declarative, second-person, lowercase-leaning, technical-fluent**. It assumes the reader builds with agents and doesn't need the basics explained.

### Tone rules
- **Second person.** "Your agents are blind to half your day." Not "users" or "people."
- **Short sentences.** Two beats per sentence. Period. Move on.
- **No hedging.** "Captures every call." Not "helps you capture most calls."
- **Concrete > abstract.** "Drafts, follow-ups, CRM updates, notes" beats "boost productivity."
- **Developer noun-stack OK.** "Webhook," "transcript," "MCP," "menu bar" — assume the reader knows.
- **No emoji.** Ever. Use mono labels (`LIVE`, `TRANSCRIBED`) for status if you need ornament.
- **Lowercase brand.** `scribe` in body copy where it reads natural; `Scribe` only when the start of a sentence demands.
- **Casing.** Sentence case for headings, buttons, labels. Never Title Case. Never ALL CAPS except for monospace eyebrows / status pills.

### Voice examples (from the brief)

> "Scribe captures every call from your Mac menu bar and turns it into fuel for your agents."

> "Half your work happens on calls and your agents can't see any of it."

> "Your agents are blind to half your day. Scribe fixes that."

### Things to avoid
- AI marketing tropes: "supercharge," "unleash," "10x," "game-changer."
- Soft verbs: "help you," "let you," "enable you to." Use the verb itself.
- Adjective stacks: "powerful, intelligent, intuitive."
- Exclamation marks. None.
- Generic stock CTAs. Prefer "Install for Mac" over "Get started."

### Microcopy patterns
- Buttons: `Install for Mac` · `Open transcript` · `Send to agent` · `Copy as JSON`
- Empty states: `No calls yet. Take one.`
- Status pills: `LIVE` · `TRANSCRIBING` · `READY` · `SENT`
- Footer tagline: `Made for people who build with agents.`

---

## Visual foundations

The aesthetic is **Vercel-meets-terminal**. Stark, monochrome, content-first. Every pixel earns its keep.

### Colors

- **Black-and-white core.** `--bg` is pure `#000` in dark, pure `#fff` in light. The primary mode is **dark** for the menu bar app and the marketing hero; light mode for docs and settings.
- **Eleven-step neutral grayscale** (`--gray-50` → `--gray-950`), OKLCH-defined for perceptual evenness. This is 90% of the palette.
- **One accent: signal blue** (`--accent`, `oklch(0.62 0.19 250)`). Reserved for primary CTAs, focus rings, and the recording-active state's secondary indicator. Never used for decoration.
- **Recording red** (`--recording`) is its own token — only ever applied to the live-recording dot.
- **Semantic colors** (success/warning/danger) exist but are used sparingly — almost always as a tinted dot or single-pixel border, never as a filled banner.

No gradients. No tints layered for depth. Color is informational, not atmospheric.

### Typography

- **Inter** (variable, 100–900, OFL) for everything — UI, body, headings. Free, open source, geometry-aligned with Geist's family of grotesques. Local woff2 in `fonts/`.
- **JetBrains Mono** (variable, OFL/Apache-2.0) for code, status pills, eyebrows, keyboard shortcuts, file paths, timestamps. Local woff2 in `fonts/`.
- Display headlines run **tight tracking** (`-0.04em`), semibold (600), never bold.
- Body is 14–15px at `--leading-relaxed` (1.65), `--fg-2` color (gray-700), max-width ~64ch.
- Mono eyebrows above section heads in `text-xs` uppercase, wide tracking.

### Spacing

15-step scale, 2px → 128px. Composes via 4px increments after `--space-3`. Tight on mobile/menu bar, generous on marketing.

### Backgrounds

- **Solid only.** `--bg` (paper or void), `--bg-subtle` (one step in), `--bg-muted` (two steps).
- **No images, no illustrations, no patterns.** The hero is text on black.
- **One exception:** an optional subtle dot grid (`background-image: radial-gradient(circle, var(--border) 1px, transparent 1px); background-size: 24px 24px;`) on the marketing hero. Used like Vercel's hero — barely visible, never decorative.

### Borders

- `1px solid var(--border)` is the default — every card, every input, every divider.
- Border IS the elevation. We rely on borders + neutral backgrounds rather than shadows to separate surfaces.
- `--border-strong` only on hover or focus.
- Focus rings: `outline: 2px solid var(--accent); outline-offset: 2px;` — never the soft inset glow style.

### Shadows

- **Almost none in dark mode.** Borders do the work.
- `--shadow-menu` for the menu bar popover (it floats off the menu bar over arbitrary desktop content — needs real elevation).
- `--shadow-md` for hover states on marketing cards in light mode only.
- No inset shadows. No colored shadows. No glows.

### Corner radii

- `--radius-md` (6px) is the default — buttons, inputs, cards.
- `--radius-lg` (8px) for the menu bar popover and modals.
- `--radius-full` for status pills and the recording dot.
- Never larger than 16px. No squircles. No pill buttons (we're not consumer).

### Motion

- **Fast and deferential.** `--duration-fast` (120ms) for hover/press. `--duration-base` (180ms) for state transitions.
- `--ease-out` (`cubic-bezier(0.22, 1, 0.36, 1)`) is the default — nothing else unless there's a reason.
- **No bounces, no springs in product UI.** Spring is reserved for the menu bar popover open animation only.
- **Recording-active waveform** is the one place we animate continuously (a 4-bar pulse, 800ms loop).
- Page-level entrance animations: a 200ms fade + 8px translate-y. That's it.

### Hover & press

- **Buttons (primary/dark):** hover lightens `--fg-1` background by ~8% (`oklch(0.20 0 0)`); press shrinks to `transform: scale(0.98)` for 80ms.
- **Buttons (secondary/border):** hover sets `border-color: var(--border-strong)` and `background: var(--bg-subtle)`. No transform.
- **Links:** hover swaps the underline from `--border-strong` to `--fg-1`.
- **List rows:** hover sets `background: var(--bg-overlay)`. Active row gets a 2px left accent border in `--fg-1`.

### Transparency & blur

- The menu bar popover backdrop uses `backdrop-filter: blur(20px)` over `rgba(0,0,0,0.7)` (dark) — this matches macOS native vibrancy.
- Modals use `--bg-scrim` (rgba(0,0,0,0.5)) — no blur.
- No glass effects elsewhere.

### Cards

- 1px border. `--radius-md` corners. `--bg` or `--bg-subtle` background.
- No shadow by default. Hover state in light mode adds `--shadow-md`.
- Padding: `--space-7` (20px) for compact, `--space-9` (32px) for marketing.

### Layout rules

- **Fixed-width nav** on marketing (1200px max). Edge-to-edge content sections separated by 1px hairline borders running corner-to-corner.
- **No floating CTAs** in the marketing site. The CTA is the hero.
- **Grid uses `gap`.** Never `margin` between siblings.
- **Asymmetry is fine.** Don't force-center if left-aligned reads better.

### Imagery (when used)

- Product screenshots are dark-mode by default, framed with a 1px `--border` and `--radius-lg`.
- No drop shadows on screenshots. No tilted/perspective-warped product shots.
- No stock photography. No illustration. If we need an image, it's a real screenshot.

---

## Iconography

Scribe uses **Lucide** ([lucide.dev](https://lucide.dev)) for all UI icons. It's loaded from a CDN; we don't bundle it.

### Why Lucide
- Stroke-based, 1.5px stroke weight, 24×24 viewBox, rounded line caps. Matches the precision of Geist.
- Massive coverage. Every icon Scribe needs (`mic`, `mic-off`, `circle-dot`, `chevron-down`, `download`, `copy`, `arrow-right`, `webhook`, `cog`, `command`) exists.
- Tree-shakeable when bundled; CDN-friendly when not.

### Usage rules
- **Stroke 1.5, never filled.** Outline-only.
- **`currentColor` for fill/stroke** so icons inherit text color.
- **Sizes:** 14px in dense menus, 16px in body buttons, 20px in nav, 24px in marketing feature blocks.
- **Pair with text wherever possible.** Icon-only buttons require a `title` attr / tooltip.

### CDN
```html
<script src="https://unpkg.com/lucide@latest"></script>
<!-- then -->
<i data-lucide="mic"></i>
<script>lucide.createIcons();</script>
```

### Brand glyphs (NOT Lucide)

- `assets/logo-mark.svg` — 5-bar waveform, the Scribe sigil. App icon, favicon, footer.
- `assets/logo-wordmark.svg` — mark + lowercase "scribe" wordmark. Marketing nav, docs.
- `assets/menubar-icon.svg` — 4-bar template-style icon for the macOS menu bar (renders monochrome via `currentColor`).
- `assets/menubar-icon-recording.svg` — same but with a 2.5px red dot. Active recording state.

These are the only hand-drawn SVGs in the system. Everything else is Lucide.

### Emoji & unicode

**Never used as UI.** No emoji in buttons, labels, or empty states. Mono text labels (`LIVE`, `READY`) carry the semantic weight emoji would normally do.

The one allowed unicode is `→` (U+2192) in CTAs: `Install for Mac →`. It pairs with Geist's letterforms cleanly and avoids loading an icon for a one-character flourish.

---

## Caveats / known gaps

- **Type:** uses Inter + JetBrains Mono (both OFL, free for any use). If you license Geist later, swap `--font-sans` / `--font-mono` in `colors_and_type.css` and drop the woff2 in `fonts/`.
- **No real product screenshots.** The UI kits are recreations from the brief, not pixel-traced from real artwork.
- **No actual Lucide bundle copied in.** We rely on the CDN. If you need offline, swap to `lucide-static` SVGs and copy them into `assets/icons/`.
