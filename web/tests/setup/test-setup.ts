import { afterEach, beforeEach } from 'vitest';
import { resetHarnessGlobals } from '../helpers/boot-main';

// Global setup for the characterization suite.
//
// jsdom provides the DOM but NOT: window.matchMedia, IntersectionObserver, a real
// 2d canvas context, or reliable requestAnimationFrame. Individual fakes are installed
// per-test via the helpers in helpers/boot-main.ts (so each test controls the exact
// configuration it needs — e.g. reduced-motion on/off, IO present/absent).
//
// This file only guarantees a CLEAN SLATE around every test: it tears down any fakes
// and DOM mutations left behind so tests cannot leak state into one another. The
// compiled module under test has module-level side effects, so leaked globals would
// otherwise silently corrupt the next test's boot.

beforeEach(() => {
  resetHarnessGlobals();
});

afterEach(() => {
  resetHarnessGlobals();
  document.body.innerHTML = '';
  document.head.innerHTML = '';
});
