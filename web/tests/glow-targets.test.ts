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
// PINNED QUIRK: the shipped HTML pages contain NO elements with class
// `.js-glow-target` and NO `data-glow` attributes — the glow hooks live only in
// `[motion-hook]` HTML comments. The `pulse-violet` class is hard-coded statically in
// the markup, not applied by JS to a `.js-glow-target`. So this suite injects synthetic
// `.js-glow-target` elements to characterize the JS path that the real markup never
// triggers. See dom-contract.test.ts, which pins the real-page absence of these hooks.

function injectGlowTargets(): HTMLElement[] {
  const main = document.getElementById('main-content')!;
  const violetDefault = document.createElement('div');
  violetDefault.className = 'js-glow-target glow-default';
  const cyanTarget = document.createElement('div');
  cyanTarget.className = 'js-glow-target glow-cyan-target';
  cyanTarget.setAttribute('data-glow', 'cyan');
  main.append(violetDefault, cyanTarget);
  return [violetDefault, cyanTarget];
}

describe('initGlowTargets', () => {
  it('does nothing when reduced-motion is on (early return)', async () => {
    installMatchMedia({ matches: true });
    installIntersectionObserver();

    mountPage('index');
    const [violetDefault, cyanTarget] = injectGlowTargets();
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
    const [violetDefault, cyanTarget] = injectGlowTargets();
    await bootMain();

    // Stagger: element i gets animationDelay === `${i * 0.6}s`.
    expect(violetDefault.style.animationDelay).toBe('0s');
    expect(cyanTarget.style.animationDelay).toBe('0.6s');

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
    const [violetDefault, cyanTarget] = injectGlowTargets();
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
});
