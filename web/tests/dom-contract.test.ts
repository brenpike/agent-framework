import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

// Characterization suite for the DOM contract main.ts depends on. This is a CONTRACT
// SNAPSHOT of the CURRENT shipped markup, read directly from disk — not a correctness
// assertion. If a structural change to the HTML would break the JS selectors, it fails
// here instead of silently in production. Where a page legitimately lacks a hook, the
// ACTUAL presence/absence is pinned (not forced).

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB_ROOT = resolve(HERE, '..');

function loadPage(file: string): Document {
  const html = readFileSync(resolve(WEB_ROOT, file), 'utf8');
  return new DOMParser().parseFromString(html, 'text/html');
}

interface PageContract {
  file: string;
  heroId: string;
  // ids of the install blocks wired as `.js-glow-target` with `data-glow="violet"`,
  // verified against the shipped markup (see the glow contract `it.each` below).
  glowTargetIds: string[];
}

// Per-page hero id, verified against the shipped markup:
//   index.html        → #hero
//   functionality.html → #func-hero
//   benefits.html     → #ben-hero
const PAGES: PageContract[] = [
  { file: 'index.html', heroId: 'hero', glowTargetIds: ['install-block', 'install-block-bottom'] },
  { file: 'functionality.html', heroId: 'func-hero', glowTargetIds: ['install-block-func', 'func-install-cta-block'] },
  { file: 'benefits.html', heroId: 'ben-hero', glowTargetIds: ['ben-install-block'] },
];

describe('DOM contract (shipped HTML)', () => {
  it.each(PAGES)('$file declares the nav + logo + hero contract main.ts queries', ({ file, heroId }) => {
    const doc = loadPage(file);

    // Mobile nav contract: initNavToggle queries all three; absence early-returns.
    expect(doc.getElementById('nav-toggle')).not.toBeNull();
    expect(doc.querySelector('.site-nav')).not.toBeNull();
    expect(doc.getElementById('nav-drawer')).not.toBeNull();

    // At least one drawer link — initNavToggle wires close-on-click for these.
    const drawerLinks = doc.querySelectorAll('#nav-drawer .site-nav__link');
    expect(drawerLinks.length).toBeGreaterThan(0);

    // The nav logo glow target queried by initGlowTargets.
    expect(doc.getElementById('nav-logo-glow')).not.toBeNull();

    // The per-page hero id that initSwarmCanvas resolves via the ?? chain.
    expect(doc.getElementById(heroId)).not.toBeNull();
  });

  it.each(PAGES)('$file references ./scripts/main.js as a module script', ({ file }) => {
    const doc = loadPage(file);
    const moduleScripts = Array.from(
      doc.querySelectorAll<HTMLScriptElement>('script[type="module"]'),
    );
    const mainScript = moduleScripts.find(
      (s) => s.getAttribute('src') === './scripts/main.js',
    );
    expect(mainScript).toBeTruthy();
  });

  it.each(PAGES)('$file uses .js-scroll-reveal with at least one data-delay value', ({ file }) => {
    const doc = loadPage(file);
    const revealTargets = doc.querySelectorAll('.js-scroll-reveal');
    expect(revealTargets.length).toBeGreaterThan(0);

    // Every shipped page uses data-delay on at least one reveal target.
    const withDelay = doc.querySelectorAll('.js-scroll-reveal[data-delay]');
    expect(withDelay.length).toBeGreaterThan(0);
  });

  it.each(PAGES)('$file wires its install blocks as the JS-driven glow contract', ({ file, glowTargetIds }) => {
    const doc = loadPage(file);

    // ACTIVATED CONTRACT (issue #147): the install blocks are now wired as
    // `.js-glow-target` with `data-glow="violet"`, so initGlowTargets is the SOLE
    // applier of the staggered pulse — no `pulse-*` class is hard-coded in the shipped
    // markup. The previous quirk (zero glow hooks; static `pulse-violet`) is gone.
    expect(doc.querySelectorAll('.js-glow-target').length).toBe(glowTargetIds.length);

    for (const id of glowTargetIds) {
      const target = doc.getElementById(id);
      expect(target, `#${id} must exist`).not.toBeNull();
      expect(target!.classList.contains('js-glow-target'), `#${id} must be a .js-glow-target`).toBe(true);
      expect(target!.getAttribute('data-glow'), `#${id} must declare data-glow="violet"`).toBe('violet');
    }

    // No element carries a static `pulse-*` class — proves JS is the sole pulse applier.
    expect(doc.querySelectorAll('[class*="pulse-"]').length).toBe(0);
  });
});
