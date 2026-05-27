import { describe, it, expect, vi, afterEach } from 'vitest';
import {
  bootMain,
  installMatchMedia,
  installIntersectionObserver,
  removeIntersectionObserver,
  installRaf,
  installCanvas2dContext,
} from './helpers/boot-main';
import { mountPage } from './fixtures';

// Characterization suite for initScrollReveal (web/src/main.ts lines 100-146).
// Pins CURRENT observable behavior: immediate is-revealed fallback when
// reduced-motion is on OR IntersectionObserver is absent; the reveal-pending →
// is-revealed swap on intersection (after the data-delay setTimeout); the
// parseInt/isNaN delay handling; and the live reduced-motion reveal of remaining
// elements. Determinism: asserts classes, observed membership, and unobserve only.
//
// The scroll-reveal IntersectionObserver is constructed FIRST in init() (before the
// swarm-canvas observer), so it is always registry index 0 when one exists.

afterEach(() => {
  vi.useRealTimers();
});

describe('initScrollReveal', () => {
  it('reveals all targets immediately and builds no observer when reduced-motion is on', async () => {
    installMatchMedia({ matches: true });
    const observers = installIntersectionObserver();

    mountPage('index');
    await bootMain();

    const targets = document.querySelectorAll<HTMLElement>('.js-scroll-reveal');
    expect(targets.length).toBeGreaterThan(0);
    targets.forEach((el) => {
      expect(el.classList.contains('is-revealed')).toBe(true);
      expect(el.classList.contains('reveal-pending')).toBe(false);
    });

    // reduced-motion gate returns before constructing the scroll-reveal observer.
    // (reduced-motion is also on, so the swarm-canvas observer is never built either.)
    expect(observers.length).toBe(0);
  });

  it('reveals all targets immediately when IntersectionObserver is absent', async () => {
    installMatchMedia({ matches: false });
    removeIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    const targets = document.querySelectorAll<HTMLElement>('.js-scroll-reveal');
    expect(targets.length).toBeGreaterThan(0);
    targets.forEach((el) => {
      expect(el.classList.contains('is-revealed')).toBe(true);
      expect(el.classList.contains('reveal-pending')).toBe(false);
    });
  });

  it('marks targets reveal-pending and observes them on the normal IO path', async () => {
    installMatchMedia({ matches: false });
    const observers = installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    const targets = document.querySelectorAll<HTMLElement>('.js-scroll-reveal');
    expect(targets.length).toBeGreaterThan(0);
    targets.forEach((el) => {
      expect(el.classList.contains('reveal-pending')).toBe(true);
      expect(el.classList.contains('is-revealed')).toBe(false);
    });

    // Observer index 0 is the scroll-reveal observer; it observed every reveal target.
    const revealObserver = observers[0];
    expect(revealObserver.observed.length).toBe(targets.length);
  });

  it('swaps reveal-pending → is-revealed and unobserves after the data-delay on intersection', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout'] });
    installMatchMedia({ matches: false });
    const observers = installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    const revealObserver = observers[0];
    // First card on index.html carries data-delay="0".
    const firstCard = document.querySelector<HTMLElement>('.js-scroll-reveal.card')!;
    expect(firstCard.dataset['delay']).toBe('0');
    expect(firstCard.classList.contains('reveal-pending')).toBe(true);

    revealObserver.trigger([{ target: firstCard, isIntersecting: true }]);

    // setTimeout(..., 0) is queued; advance fake timers to flush it.
    vi.advanceTimersByTime(0);

    expect(firstCard.classList.contains('reveal-pending')).toBe(false);
    expect(firstCard.classList.contains('is-revealed')).toBe(true);
    // Element is unobserved synchronously inside the IO callback.
    expect(revealObserver.observed).not.toContain(firstCard);
  });

  it('honors a positive data-delay before swapping the reveal classes', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout'] });
    installMatchMedia({ matches: false });
    const observers = installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    const revealObserver = observers[0];
    // A card with data-delay="100" exists in the bioforms grid.
    const delayedCard = Array.from(
      document.querySelectorAll<HTMLElement>('.js-scroll-reveal'),
    ).find((el) => el.dataset['delay'] === '100')!;
    expect(delayedCard).toBeTruthy();

    revealObserver.trigger([{ target: delayedCard, isIntersecting: true }]);

    // Before the delay elapses, the swap has NOT happened yet.
    vi.advanceTimersByTime(99);
    expect(delayedCard.classList.contains('is-revealed')).toBe(false);
    expect(delayedCard.classList.contains('reveal-pending')).toBe(true);

    // After the full delay, the swap fires.
    vi.advanceTimersByTime(1);
    expect(delayedCard.classList.contains('is-revealed')).toBe(true);
    expect(delayedCard.classList.contains('reveal-pending')).toBe(false);
  });

  it('treats missing and non-numeric data-delay as 0 (parseInt/isNaN handling)', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout'] });
    installMatchMedia({ matches: false });
    const observers = installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    // Inject synthetic reveal targets to exercise the delay-parsing branches that the
    // shipped pages do not cover: a missing data-delay (defaults to '0') and a
    // non-numeric data-delay (parseInt → NaN → coerced to 0).
    mountPage('index');
    const main = document.getElementById('main-content')!;
    const noDelay = document.createElement('div');
    noDelay.className = 'js-scroll-reveal synthetic-no-delay';
    const nanDelay = document.createElement('div');
    nanDelay.className = 'js-scroll-reveal synthetic-nan-delay';
    nanDelay.setAttribute('data-delay', 'not-a-number');
    main.append(noDelay, nanDelay);

    await bootMain();

    const revealObserver = observers[0];

    // PINNED QUIRK: a missing data-delay is read as `el.dataset['delay'] ?? '0'`,
    // and a non-numeric value parseInts to NaN which is then coerced to 0. Both reveal
    // on the same tick as a delay-0 element — no distinction is observable.
    revealObserver.trigger([
      { target: noDelay, isIntersecting: true },
      { target: nanDelay, isIntersecting: true },
    ]);
    vi.advanceTimersByTime(0);

    expect(noDelay.classList.contains('is-revealed')).toBe(true);
    expect(nanDelay.classList.contains('is-revealed')).toBe(true);
  });

  it('does nothing for a non-intersecting entry (isIntersecting false guard)', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout'] });
    installMatchMedia({ matches: false });
    const observers = installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    const revealObserver = observers[0];
    const card = document.querySelector<HTMLElement>('.js-scroll-reveal.card')!;

    revealObserver.trigger([{ target: card, isIntersecting: false }]);
    vi.advanceTimersByTime(1000);

    // The `if (!entry.isIntersecting) return;` guard leaves the element pending and observed.
    expect(card.classList.contains('reveal-pending')).toBe(true);
    expect(card.classList.contains('is-revealed')).toBe(false);
    expect(revealObserver.observed).toContain(card);
  });

  it('reveals remaining pending elements on a live reduced-motion change', async () => {
    const mql = installMatchMedia({ matches: false });
    installIntersectionObserver();
    installRaf();
    installCanvas2dContext();

    mountPage('index');
    await bootMain();

    const targets = document.querySelectorAll<HTMLElement>('.js-scroll-reveal');
    targets.forEach((el) => {
      expect(el.classList.contains('reveal-pending')).toBe(true);
    });

    // Drive a live preference change to reduced-motion: on.
    mql._fireChange(true);

    targets.forEach((el) => {
      expect(el.classList.contains('is-revealed')).toBe(true);
      expect(el.classList.contains('reveal-pending')).toBe(false);
    });
  });
});
