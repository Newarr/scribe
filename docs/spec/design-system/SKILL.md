---
name: scribe-design
description: Use this skill to generate well-branded interfaces and assets for Scribe, either for production or throwaway prototypes/mocks/etc. Contains essential design guidelines, colors, type, fonts, assets, and UI kit components for prototyping.
user-invocable: true
---

Read the README.md file within this skill, and explore the other available files.

If creating visual artifacts (slides, mocks, throwaway prototypes, etc), copy assets out and create static HTML files for the user to view. If working on production code, you can copy assets and read the rules here to become an expert in designing with this brand.

If the user invokes this skill without any other guidance, ask them what they want to build or design, ask some questions, and act as an expert designer who outputs HTML artifacts _or_ production code, depending on the need.

## What's in this skill

- `README.md` — brand context, content fundamentals, visual foundations, iconography
- `colors_and_type.css` — all design tokens (CSS variables) + base element styles
- `assets/` — logo mark, wordmark, menu bar icons
- `preview/` — small spec cards (type, color, components)
- `ui_kits/marketing/` — landing page recreation
- `ui_kits/menubar/` — menu bar app popover recreation

## Quick reminders

- Voice: terse, second-person, no hedging, no emoji, sentence case
- Default mode: dark (`#000` bg, white text, `oklch(0.62 0.19 250)` signal-blue accent)
- Type: Geist + Geist Mono, semibold (600) max for display, tight tracking
- No gradients, no illustrations, no colored shadows. Borders carry elevation.
- Icons: Lucide via CDN, 1.5 stroke, currentColor
