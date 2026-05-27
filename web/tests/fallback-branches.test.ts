import { describe, it, expect, vi } from 'vitest';
import {
  bootMain,
  installMatchMedia,
  installIntersectionObserver,
  removeIntersectionObserver,
  installRaf,
  installCanvas2dContext,
} from './helpers/boot-main';
import { mountPage } from './fixtures';

// Characterization suite for the legacy / absent-API fallback branches in main.ts.
// Pins CURRENT observable behavior of: the deprecated WebKit addListener path in
// onMotionChange (lines 35-41), and the IntersectionObserver-absent branches in both
// initScrollReveal (immediate reveal) and initSwarmCanvas (direct start(), lines 352-354).

describe('fallback branches', () => {
  it('registers the motion-change listener via the deprecated addListener when addEventListener is absent', async () => {
    // legacy:true omits addEventListener, leaving only the deprecated addListener.
    const mql = installMatchMedia({ matches: false, legacy: true });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    // Spy on the legacy registrar BEFORE boot so we can prove main.js used it.
    const addListenerSpy = vi.spyOn(mql, 'addListener');

    mountPage('index');
    // onMotionChange is invoked by initScrollReveal, initGlowTargets, and initSwarmCanvas;
    // with no addEventListener available it must fall through to addListener each time.
    await expect(bootMain()).resolves.toBeUndefined();

    expect(addListenerSpy).toHaveBeenCalled();
    // The listener registered is a function (the live-change handler).
    expect(typeof addListenerSpy.mock.calls[0][0]).toBe('function');
  });

  it('takes the immediate-reveal AND direct-start paths when IntersectionObserver is absent', async () => {
    installMatchMedia({ matches: false });
    removeIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    // initScrollReveal sees no IO → immediate is-revealed fallback.
    // initSwarmCanvas sees no IO → calls start() directly (lines 352-354) and begins
    // ticking; installRaf keeps that from looping. Neither must throw.
    await expect(bootMain()).resolves.toBeUndefined();

    const targets = document.querySelectorAll<HTMLElement>('.js-scroll-reveal');
    expect(targets.length).toBeGreaterThan(0);
    targets.forEach((el) => {
      expect(el.classList.contains('is-revealed')).toBe(true);
      expect(el.classList.contains('reveal-pending')).toBe(false);
    });

    // The hero canvas is still created (IO absence does not gate canvas creation).
    expect(document.querySelector('canvas')).not.toBeNull();
  });
});
