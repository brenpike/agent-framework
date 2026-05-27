import { describe, it, expect } from 'vitest';
import {
  bootMain,
  installMatchMedia,
  installIntersectionObserver,
  installRaf,
  installCanvas2dContext,
} from './helpers/boot-main';
import { mountPage } from './fixtures';

// Characterization suite for initGlowTargets (web/src/main.ts lines 152-181).
// Pins CURRENT observable behavior: the reduced-motion early return; the staggered
// inline animationDelay + pulse-<glow> class (defaulting to violet when data-glow is
// absent); the #nav-logo-glow → nav-logo-pulse class; and the live reduced-motion
// revert. Determinism: asserts inline style strings and classes only.
//
// ACTIVATED CONTRACT (issue #147): the shipped install blocks ARE now wired as
// `.js-glow-target` with `data-glow="violet"`, so initGlowTargets drives the staggered
// pulse on the real markup (it is the sole `pulse-*` applier — no static `pulse-*` class
// remains). The synthetic-injection tests below stay valid because main.ts's glow logic
// is unchanged; they isolate per-element behavior (default-violet, data-glow="cyan",
// reduced-motion revert) independent of which real ids happen to be wired. One
// real-markup test then proves the wiring fires end-to-end on a shipped page. See
// dom-contract.test.ts, which pins the per-page glow-target id contract.

// Inject two synthetic `.js-glow-target` elements at the END of the mounted DOM and
// return them alongside their DOCUMENT-ORDER base index. initGlowTargets staggers by
// `${i * 0.6}s` across ALL `.js-glow-target` in document order, so the synthetic pair's
// delay depends on how many real targets the mounted page already ships ahead of them.
// Capturing `baseIndex` keeps these per-element characterization assertions valid
// regardless of the shipped page's real glow-target count (issue #147 wired real ones).
function injectGlowTargets(): { violetDefault: HTMLElement; cyanTarget: HTMLElement; baseIndex: number } {
  const main = document.getElementById('main-content')!;
  const baseIndex = document.querySelectorAll('.js-glow-target').length;
  const violetDefault = document.createElement('div');
  violetDefault.className = 'js-glow-target glow-default';
  const cyanTarget = document.createElement('div');
  cyanTarget.className = 'js-glow-target glow-cyan-target';
  cyanTarget.setAttribute('data-glow', 'cyan');
  main.append(violetDefault, cyanTarget);
  return { violetDefault, cyanTarget, baseIndex };
}

describe('initGlowTargets', () => {
  it('does nothing when reduced-motion is on (early return)', async () => {
    installMatchMedia({ matches: true });
    installIntersectionObserver();

    mountPage('index');
    const { violetDefault, cyanTarget } = injectGlowTargets();
    await bootMain();

    expect(violetDefault.style.animationDelay).toBe('');
    expect(cyanTarget.style.animationDelay).toBe('');
    expect(violetDefault.classList.contains('pulse-violet')).toBe(false);
    expect(cyanTarget.classList.contains('pulse-cyan')).toBe(false);

    const logo = document.getElementById('nav-logo-glow')!;
    expect(logo.classList.contains('nav-logo-pulse')).toBe(false);
  });

  it('staggers animationDelay and applies pulse-<glow> + nav-logo-pulse when reduced-motion is off', async () => {
    installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    const { violetDefault, cyanTarget, baseIndex } = injectGlowTargets();
    await bootMain();

    // Stagger: element i gets animationDelay === `${i * 0.6}s` by DOCUMENT order across
    // ALL `.js-glow-target`. The synthetic pair sits AFTER the page's real targets, so
    // assert relative to its document-order base index.
    expect(violetDefault.style.animationDelay).toBe(`${baseIndex * 0.6}s`);
    expect(cyanTarget.style.animationDelay).toBe(`${(baseIndex + 1) * 0.6}s`);

    // Default glow color is violet when data-glow is absent.
    expect(violetDefault.classList.contains('pulse-violet')).toBe(true);
    // data-glow="cyan" → pulse-cyan.
    expect(cyanTarget.classList.contains('pulse-cyan')).toBe(true);

    // The nav logo always gets nav-logo-pulse on the active path.
    const logo = document.getElementById('nav-logo-glow')!;
    expect(logo.classList.contains('nav-logo-pulse')).toBe(true);
  });

  it('reverts pulse classes, clears animationDelay, and unpulses the logo on a live reduced-motion change', async () => {
    const mql = installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    const { violetDefault, cyanTarget } = injectGlowTargets();
    await bootMain();

    // Sanity: active state applied first.
    expect(violetDefault.classList.contains('pulse-violet')).toBe(true);
    expect(cyanTarget.classList.contains('pulse-cyan')).toBe(true);
    const logo = document.getElementById('nav-logo-glow')!;
    expect(logo.classList.contains('nav-logo-pulse')).toBe(true);

    // Live change to reduced-motion: on → revert.
    mql._fireChange(true);

    expect(violetDefault.classList.contains('pulse-violet')).toBe(false);
    expect(cyanTarget.classList.contains('pulse-cyan')).toBe(false);
    expect(violetDefault.style.animationDelay).toBe('');
    expect(cyanTarget.style.animationDelay).toBe('');
    expect(logo.classList.contains('nav-logo-pulse')).toBe(false);
  });

  it('applies pulse-violet + a staggered animationDelay to real shipped .js-glow-target markup', async () => {
    installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    // benefits is a hero page: with motion on, main.js constructs the swarm canvas and
    // throws without a 2d-context stub. Install it before boot per the harness contract.
    installCanvas2dContext();

    mountPage('benefits');
    await bootMain();

    const realTarget = document.getElementById('ben-install-block')!;
    expect(realTarget.classList.contains('js-glow-target')).toBe(true);
    // initGlowTargets applied the pulse — no static pulse-* class exists in the markup.
    expect(realTarget.classList.contains('pulse-violet')).toBe(true);

    // Stagger is `${i * 0.6}s` by DOCUMENT order across all `.js-glow-target`. Assert the
    // value is a non-empty `Ns` string, and that the first target in document order is `0s`.
    expect(realTarget.style.animationDelay).toMatch(/^\d+(?:\.\d+)?s$/);

    const firstTarget = document.querySelector<HTMLElement>('.js-glow-target')!;
    expect(firstTarget.style.animationDelay).toBe('0s');
  });
});
