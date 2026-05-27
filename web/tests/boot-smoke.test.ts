import { describe, it, expect } from 'vitest';
import {
  bootMain,
  installMatchMedia,
  installIntersectionObserver,
  installRaf,
  installCanvas2dContext,
} from './helpers/boot-main';
import { mountPage } from './fixtures';

// Smoke proof for the characterization harness. This is the harness's living proof
// that it can install the required fakes, mount a real page, boot the COMPILED module,
// and observe at least one effect of init() running. It is NOT a behavior-pinning suite
// (that is Phase 2) — keep it minimal and keep it green.

describe('harness boot smoke', () => {
  it('boots the compiled site JS against the real index.html and runs init()', async () => {
    // Install fakes BEFORE bootMain. matchMedia is read at module-eval time.
    installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    // Observable effect 1: scroll-reveal ran. With IO present + reduced-motion off,
    // initScrollReveal adds 'reveal-pending' to every .js-scroll-reveal element.
    const revealTargets = document.querySelectorAll('.js-scroll-reveal');
    expect(revealTargets.length).toBeGreaterThan(0);
    revealTargets.forEach((el) => {
      expect(el.classList.contains('reveal-pending')).toBe(true);
    });

    // Observable effect 2: nav toggle wiring. Clicking #nav-toggle opens the drawer and
    // flips aria-expanded — proves initNavToggle bound its click handler to the real DOM.
    const toggle = document.getElementById('nav-toggle');
    const nav = document.querySelector('.site-nav');
    expect(toggle).not.toBeNull();
    expect(toggle?.getAttribute('aria-expanded')).toBe('false');

    toggle?.dispatchEvent(new MouseEvent('click', { bubbles: true }));

    expect(toggle?.getAttribute('aria-expanded')).toBe('true');
    expect(nav?.hasAttribute('data-nav-open')).toBe(true);
  });
});
