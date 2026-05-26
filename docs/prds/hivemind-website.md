# PRD: Hivemind Plugin Website

## Problem Statement

The hivemind plugin's only public-facing surface is its README. Developers discovering the project on GitHub must parse a long, dense README to understand what the plugin is, how its multi-agent system works, what problems it solves, and how to install it. There is no inviting, scannable, themed entry point that communicates the project's identity and value at a glance. Prospective adopters benefit from a focused informational site that conveys the high-level pitch, lets them go deeper on demand, and reinforces the project's distinct "hivemind" character — lowering the effort to evaluate and adopt the plugin.

## Solution

A small, statically-served informational website for the hivemind plugin, themed around a dark alien-hive / space aesthetic. The site mirrors README content (which remains the canonical source of truth) across a landing page plus two detail pages:

- A landing page that delivers the high-level pitch and feature highlights (the bioforms, the lifecycle, brood/parallel mode, signals) with a primary call-to-action to install and a direct link to the GitHub repository.
- A functionality/usage page covering install commands, requirements, per-project setup, the agents and skills, the lifecycle in detail, brood mode, signals, and optional companion plugins.
- A benefits page articulating the problems the plugin solves and the value it delivers.

The visual identity evokes an alien hive civilization (Zerg, Slivers, Tyranids) and deep space: bio-luminescent neon accents on a near-black carapace base, organic gradients, subtle membrane/scanline texture, chitinous geometric shapes, and tasteful motion that makes the site "feel alive" — with neon used sparingly as a danger/alive signal rather than everywhere. The site is publicly deployed so the project has a shareable home page beyond the GitHub README.

## User Stories

- As a developer evaluating hivemind, I want a high-level overview of what the plugin does, so that I can decide if it fits my workflow.
- As a developer, I want install and per-project setup instructions, so that I can get the plugin running in my project.
- As a developer, I want a detailed breakdown of the bioforms, skills, the lifecycle, and brood mode, so that I understand how the system works.
- As a developer, I want to see the problems the plugin solves and the benefits it delivers, so that I can justify adopting it.
- As a visitor, I want the visual design to convey the hivemind theme, so that the project is memorable and distinct.
- As a visitor, I want direct links to the GitHub repository from the website, so that I can view the source, star, or contribute.

## Acceptance Criteria

- The site presents a landing page plus two detail pages (functionality/usage, benefits), navigable between one another.
- The landing page communicates the plugin's one-line pitch, high-level feature highlights (bioforms, lifecycle, brood, signals), a clear install call-to-action, and a visible link to the GitHub repository.
- The functionality page contains install commands, requirements, per-project setup guidance, the agents and skills, a lifecycle explanation, brood mode, signals, and the optional companion plugins — factually consistent with the README, with no invented features.
- The benefits page states the problems solved and the value delivered, without overpromising beyond README claims.
- A direct link to the GitHub repository is reachable from every page.
- The site renders correctly when served under the GitHub Pages project base path (asset and internal links resolve, not broken by an absolute-root assumption).
- The site is responsive and usable on both desktop and mobile widths.
- The visual theme (dark alien-hive/space, bio-luminescent neon accents, motion that feels alive) is applied consistently across all pages.
- Motion/animation respects a reduced-motion user preference: when reduced motion is requested, non-essential animation is disabled.
- Text and interactive elements meet a reasonable contrast/legibility bar against the dark theme.
- The published site is reachable at its public URL after deployment.

## Implementation Decisions

- The website is a separate marketing/informational artifact that lives outside the plugin runtime boundary. It is not packaged plugin runtime data, carries no plugin version impact, and does not trigger a version bump or a CHANGELOG entry.
- The site is statically served with no runtime application framework and no server/backend.
- Page markup and styling are hand-authored. Client-side behavior is authored in TypeScript and compiled to JavaScript at deploy time; the compiled output is a build artifact and is not committed to the repository.
- The README remains the canonical source of truth for install/usage/feature content; the site mirrors it, and a source-of-truth convention is documented so the two do not silently drift.
- Deployment is via GitHub Pages, published automatically on integration to the trunk. The deployment path must not alter the existing repository policy/CI checks.
- Because the site is served under a project (sub-path) base, internal and asset references must be base-path-safe rather than assuming a root-level origin.
- Display and monospace fonts are self-hosted under an open font license rather than loaded from a third-party font CDN, to avoid an external runtime dependency.

## Testing Decisions

- Manual cross-browser and responsive verification at desktop and mobile widths confirms layout, navigation between pages, and that all internal/asset links resolve under the Pages base path.
- Verification that the reduced-motion preference disables non-essential animation.
- A legibility/contrast spot-check of text and interactive elements against the dark theme.
- Confirmation that the deploy build (TypeScript compile + publish) succeeds and that the published site loads at its public URL with working repository links.
- Confirmation that adding the site does not cause the repository's existing policy/CI checks to fail.

## Success Metrics

- The site is live at its public GitHub Pages URL and reachable from the repository.
- A first-time visitor can locate install instructions and reach the GitHub repository from the landing page without scrolling past the primary content region.
- Content on the site matches the README's factual claims (no contradictions or invented features) at launch.
- The site loads quickly as a static page with no blocking external font/asset dependency.

## Out of Scope

- Interactive demos, a live plugin playground, or running the plugin in-browser.
- Any backend, server, API, search, or analytics.
- Blog, changelog feed, documentation versioning, or multi-version docs.
- Content beyond README scope (no extended tutorials, no full API reference).
- Modifying the README, plugin runtime, or the existing policy-check CI workflow.
- Internationalization / multi-language support.
- Custom domain setup (uses the default GitHub Pages URL).

## Further Notes

- Content-drift management relies on a documented "README is canonical" convention rather than an automated sync mechanism; an automated mirror/sync is a possible future enhancement but is not part of this Initiative.
- Exact font selections, palette hex values, and specific animation choices are left to presentational implementation within the locked theme direction (dark alien-hive/space, bio-luminescent neon on near-black carapace, sparing use of neon as a danger/alive signal).
