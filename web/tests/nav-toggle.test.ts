import { describe, it, expect } from 'vitest';
import {
  bootMain,
  installMatchMedia,
  installIntersectionObserver,
  installRaf,
  installCanvas2dContext,
} from './helpers/boot-main';
import { mountPage, mountMinimalDom } from './fixtures';

// Characterization suite for initNavToggle (web/src/main.ts lines 47-94).
// Pins CURRENT observable behavior: data-nav-open attribute, aria-expanded /
// aria-hidden sync, link-click close, Escape close, and toggle refocus.
// Determinism: asserts attributes, classes, element presence, and activeElement
// only — never timing, particle, or random-driven state.

describe('initNavToggle', () => {
  it('does not throw and binds no nav state when the nav contract is absent', async () => {
    installMatchMedia({ matches: false });
    installIntersectionObserver();

    mountMinimalDom();
    await bootMain();

    // The minimal DOM omits #nav-toggle / .site-nav / #nav-drawer, so initNavToggle
    // hits `if (!toggle || !nav || !drawer) return;` before binding any listener.
    expect(document.getElementById('nav-toggle')).toBeNull();
    expect(document.querySelector('.site-nav')).toBeNull();
    expect(document.getElementById('nav-drawer')).toBeNull();

    // Dispatching Escape with no listener bound must not throw.
    expect(() =>
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })),
    ).not.toThrow();
  });

  it('opens the drawer on toggle click when closed (openNav)', async () => {
    installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    const toggle = document.getElementById('nav-toggle')!;
    const nav = document.querySelector('.site-nav')!;
    const drawer = document.getElementById('nav-drawer')!;

    // Initial shipped markup state.
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    expect(drawer.getAttribute('aria-hidden')).toBe('true');
    expect(nav.hasAttribute('data-nav-open')).toBe(false);

    toggle.dispatchEvent(new MouseEvent('click', { bubbles: true }));

    expect(nav.hasAttribute('data-nav-open')).toBe(true);
    expect(toggle.getAttribute('aria-expanded')).toBe('true');
    expect(drawer.getAttribute('aria-hidden')).toBe('false');
  });

  it('closes the drawer and refocuses the toggle on a second click (closeNav)', async () => {
    installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    const toggle = document.getElementById('nav-toggle')!;
    const nav = document.querySelector('.site-nav')!;
    const drawer = document.getElementById('nav-drawer')!;

    toggle.dispatchEvent(new MouseEvent('click', { bubbles: true })); // open
    toggle.dispatchEvent(new MouseEvent('click', { bubbles: true })); // close

    expect(nav.hasAttribute('data-nav-open')).toBe(false);
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    expect(drawer.getAttribute('aria-hidden')).toBe('true');
    // closeNav calls toggle.focus() — activeElement becomes the toggle.
    expect(document.activeElement).toBe(toggle);
  });

  it('closes the drawer when a .site-nav__link inside the drawer is clicked', async () => {
    installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    const toggle = document.getElementById('nav-toggle')!;
    const nav = document.querySelector('.site-nav')!;
    const drawer = document.getElementById('nav-drawer')!;

    toggle.dispatchEvent(new MouseEvent('click', { bubbles: true })); // open
    expect(nav.hasAttribute('data-nav-open')).toBe(true);

    const drawerLink = drawer.querySelector<HTMLAnchorElement>('.site-nav__link')!;
    drawerLink.dispatchEvent(new MouseEvent('click', { bubbles: true }));

    expect(nav.hasAttribute('data-nav-open')).toBe(false);
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    expect(drawer.getAttribute('aria-hidden')).toBe('true');
    expect(document.activeElement).toBe(toggle);
  });

  it('closes the drawer on Escape when open and refocuses the toggle', async () => {
    installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    const toggle = document.getElementById('nav-toggle')!;
    const nav = document.querySelector('.site-nav')!;
    const drawer = document.getElementById('nav-drawer')!;

    toggle.dispatchEvent(new MouseEvent('click', { bubbles: true })); // open
    expect(nav.hasAttribute('data-nav-open')).toBe(true);

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));

    expect(nav.hasAttribute('data-nav-open')).toBe(false);
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    expect(drawer.getAttribute('aria-hidden')).toBe('true');
    expect(document.activeElement).toBe(toggle);
  });

  it('leaves a closed drawer unchanged when Escape is pressed (Escape no-op when closed)', async () => {
    installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    const toggle = document.getElementById('nav-toggle')!;
    const nav = document.querySelector('.site-nav')!;
    const drawer = document.getElementById('nav-drawer')!;

    // Drawer starts closed; Escape guard is `e.key === 'Escape' && isOpen()`.
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));

    expect(nav.hasAttribute('data-nav-open')).toBe(false);
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    expect(drawer.getAttribute('aria-hidden')).toBe('true');
  });
});
