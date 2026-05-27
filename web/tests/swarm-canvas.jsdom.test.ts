import { describe, it, expect, vi } from 'vitest';
import {
  bootMain,
  installMatchMedia,
  installIntersectionObserver,
  installRaf,
  installCanvas2dContext,
} from './helpers/boot-main';
import { mountPage, mountMinimalDom } from './fixtures';

// Characterization suite for initSwarmCanvas (web/src/main.ts lines 229-380).
//
// CONTRACT ONLY. The swarm canvas is a decorative particle field. Per the project's
// determinism policy, the following are DELIBERATELY UNCHARACTERIZED:
//   - particle positions, velocities, counts, alpha values
//   - pixel output / rendered frames
//   - requestAnimationFrame timing and frame cadence
//   - any Math.random-driven value (color choice, spawn position, pulse speed)
// We assert only: canvas element presence/absence, its aria-hidden attribute and inline
// cssText, the jsdom-specific position behavior, and 2d-context lifecycle CALL occurrence.

describe('initSwarmCanvas (contract)', () => {
  it('appends no canvas when there is no hero section', async () => {
    installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountMinimalDom();
    await bootMain();

    expect(document.querySelector('canvas')).toBeNull();
  });

  it('appends no canvas when reduced-motion is on even with a hero present', async () => {
    installMatchMedia({ matches: true });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    // Hero #hero exists, but the `if (prefersReducedMotion()) return;` gate fires
    // before the canvas is created.
    expect(document.getElementById('hero')).not.toBeNull();
    expect(document.querySelector('canvas')).toBeNull();
  });

  it('prepends exactly one decorative canvas to the hero with the documented attributes', async () => {
    installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    const hero = document.getElementById('hero')!;
    const canvases = document.querySelectorAll('canvas');
    expect(canvases.length).toBe(1);

    const canvas = canvases[0] as HTMLCanvasElement;
    // prepend() puts the canvas as the hero's first child.
    expect(hero.firstElementChild).toBe(canvas);
    expect(canvas.getAttribute('aria-hidden')).toBe('true');

    // The documented inline cssText — pointer-events:none plus the absolute overlay.
    const css = canvas.style.cssText;
    expect(css).toContain('pointer-events: none');
    expect(css).toContain('position: absolute');
    expect(css).toContain('inset: 0');
    expect(css).toContain('width: 100%');
    expect(css).toContain('height: 100%');
    expect(css).toContain('z-index: 0');

    // PINNED QUIRK: under jsdom, getComputedStyle(hero).position returns '' (not
    // 'static'), so the `if (heroStyle.position === 'static')` branch does NOT fire and
    // hero.style.position is never set. In a real browser this would be set to 'relative'.
    expect(hero.style.position).toBe('');
  });

  it('leaves the canvas orphaned in the DOM and stops when the 2d context is null', async () => {
    installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    // Force getContext to return null to drive the `if (!ctx) return;` early exit.
    Object.defineProperty(HTMLCanvasElement.prototype, 'getContext', {
      configurable: true,
      writable: true,
      value: vi.fn(() => null),
    });

    mountPage('index');
    await bootMain();

    const hero = document.getElementById('hero')!;
    const canvas = document.querySelector('canvas');

    // PINNED QUIRK: the canvas is prepended to the hero BEFORE the `const ctx =
    // canvas.getContext('2d'); if (!ctx) return;` check. So on a null context the
    // <canvas> remains in the DOM (orphaned — no animation, no listeners wired), and
    // init returns early. This is a latent quirk: a no-op canvas is left attached.
    expect(canvas).not.toBeNull();
    expect(hero.firstElementChild).toBe(canvas);
  });

  it('clears the canvas via the 2d context on a live reduced-motion change', async () => {
    const mql = installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    const ctxSpy = installCanvas2dContext();

    mountPage('index');
    await bootMain();

    // The live reduced-motion handler runs `stop(); ctx.clearRect(...)`. Assert only that
    // clearRect was CALLED on the change — never arc/fill counts or coordinates.
    const clearRectCallsBefore = ctxSpy.clearRect.mock.calls.length;
    mql._fireChange(true);

    expect(ctxSpy.clearRect.mock.calls.length).toBeGreaterThan(clearRectCallsBefore);
  });
});
