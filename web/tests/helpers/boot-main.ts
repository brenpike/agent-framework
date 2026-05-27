import { vi } from 'vitest';

// ---------------------------------------------------------------------------
// Harness for booting the COMPILED website module (web/scripts/main.js) against
// a jsdom DOM with controllable fakes for the browser APIs main.ts touches.
//
// Decision: fakes are HAND-ROLLED (not jsdom-testing-mocks / vitest-canvas-mock).
// Phase 2 needs precise, per-test control — toggle matchMedia legacy vs modern,
// fire IntersectionObserver entries manually, delete IO to hit the absent branch,
// and assert exact 2d-context lifecycle calls. A hand-rolled surface exposes all of
// that directly; third-party libs would hide it behind their own conventions.
// ---------------------------------------------------------------------------

// Absolute-from-repo-root path to the compiled artifact. main.ts has no exports and
// self-boots on evaluation, so importing this file runs init() against the current DOM.
const COMPILED_MAIN = '../../scripts/main.js';

// ---------------------------------------------------------------------------
// matchMedia fake
// ---------------------------------------------------------------------------

export interface FakeMediaQueryList {
  matches: boolean;
  media: string;
  onchange: null;
  // Modern listeners (omitted entirely when `legacy` is set).
  addEventListener?: (type: string, listener: (e: MediaQueryListEvent) => void) => void;
  removeEventListener?: (type: string, listener: (e: MediaQueryListEvent) => void) => void;
  dispatchEvent?: (event: Event) => boolean;
  // Legacy WebKit listeners (always present so the deprecated path can be exercised).
  addListener: (listener: (e: MediaQueryListEvent) => void) => void;
  removeListener: (listener: (e: MediaQueryListEvent) => void) => void;
  // Test-only: drive a live preference change to all registered listeners.
  _fireChange: (matches: boolean) => void;
}

export interface MatchMediaOptions {
  // Initial value of MediaQueryList.matches (i.e. prefers-reduced-motion state).
  matches?: boolean;
  // When true, the MediaQueryList omits addEventListener and exposes only the
  // deprecated addListener — exercising main.ts's legacy WebKit fallback path.
  legacy?: boolean;
}

let lastMediaQueryList: FakeMediaQueryList | null = null;

// Install window.matchMedia. MUST be called BEFORE bootMain — main.js reads matchMedia
// at module-eval time (top-level `const motionQuery = window.matchMedia(...)`), so an
// absent fake makes the import throw. Returns the MediaQueryList the module will hold,
// so a test can flip `.matches` and call `_fireChange` to drive live preference changes.
export function installMatchMedia(opts: MatchMediaOptions = {}): FakeMediaQueryList {
  const matches = opts.matches ?? false;
  const legacy = opts.legacy ?? false;
  const changeListeners = new Set<(e: MediaQueryListEvent) => void>();

  const mql: FakeMediaQueryList = {
    matches,
    media: '(prefers-reduced-motion: reduce)',
    onchange: null,
    addListener: (listener) => changeListeners.add(listener),
    removeListener: (listener) => changeListeners.delete(listener),
    _fireChange(next: boolean) {
      this.matches = next;
      const event = { matches: next, media: this.media } as MediaQueryListEvent;
      changeListeners.forEach((listener) => listener(event));
    },
  };

  if (!legacy) {
    mql.addEventListener = (_type, listener) => changeListeners.add(listener);
    mql.removeEventListener = (_type, listener) => changeListeners.delete(listener);
    mql.dispatchEvent = () => true;
  }

  lastMediaQueryList = mql;
  Object.defineProperty(window, 'matchMedia', {
    configurable: true,
    writable: true,
    value: vi.fn(() => mql),
  });
  return mql;
}

// ---------------------------------------------------------------------------
// IntersectionObserver fake
// ---------------------------------------------------------------------------

export interface FakeIntersectionObserver {
  callback: IntersectionObserverCallback;
  options?: IntersectionObserverInit;
  observed: Element[];
  observe: (el: Element) => void;
  unobserve: (el: Element) => void;
  disconnect: () => void;
  // Test-only: invoke the observer callback with synthetic entries.
  trigger: (entries: Array<Partial<IntersectionObserverEntry> & { target: Element }>) => void;
}

// Registry of all IntersectionObserver instances main.js constructs during a boot.
// main.js builds up to two: one for scroll-reveal, one for the swarm canvas.
const intersectionObservers: FakeIntersectionObserver[] = [];

// Install a controllable IntersectionObserver. Returns the registry array (shared
// reference) so a test can reach into a created instance and call `.trigger(...)`
// with synthetic entries to drive the reveal / canvas-visibility callbacks.
export function installIntersectionObserver(): FakeIntersectionObserver[] {
  intersectionObservers.length = 0;

  class IO {
    constructor(callback: IntersectionObserverCallback, options?: IntersectionObserverInit) {
      const instance: FakeIntersectionObserver = {
        callback,
        options,
        observed: [],
        observe: (el: Element) => {
          instance.observed.push(el);
        },
        unobserve: (el: Element) => {
          instance.observed = instance.observed.filter((e) => e !== el);
        },
        disconnect: () => {
          instance.observed = [];
        },
        trigger: (entries) => {
          callback(
            entries as unknown as IntersectionObserverEntry[],
            instance as unknown as IntersectionObserver,
          );
        },
      };
      intersectionObservers.push(instance);
      // Return the plain instance so main.js's `new IntersectionObserver(...)` yields
      // an object exposing observe/unobserve/disconnect.
      return instance as unknown as IO;
    }
  }

  Object.defineProperty(window, 'IntersectionObserver', {
    configurable: true,
    writable: true,
    value: IO as unknown as typeof IntersectionObserver,
  });
  return intersectionObservers;
}

// Delete IntersectionObserver from the global to exercise main.js's absent branch
// (`'IntersectionObserver' in window` → false). Call BEFORE bootMain.
export function removeIntersectionObserver(): void {
  intersectionObservers.length = 0;
  // Reflect.deleteProperty so a subsequent `'IntersectionObserver' in window` is false.
  Reflect.deleteProperty(window, 'IntersectionObserver');
  Reflect.deleteProperty(globalThis as unknown as Record<string, unknown>, 'IntersectionObserver');
}

// ---------------------------------------------------------------------------
// requestAnimationFrame / cancelAnimationFrame fakes
// ---------------------------------------------------------------------------

// Install rAF/cAF fakes. Only needed when NOT using vi.useFakeTimers. When a test uses
// fake timers and needs rAF, prefer:
//   vi.useFakeTimers({ toFake: ['requestAnimationFrame', 'cancelAnimationFrame', ...] })
// because Vitest does not fake rAF/cAF by default.
//
// These fakes do NOT auto-run the callback — that would create an unbounded loop
// (main.js's tick() re-schedules itself). The returned controller lets a test flush a
// single frame deliberately, keeping rAF timing out of the assertions.
export interface RafController {
  flushOne: () => void;
  pending: () => number;
}

export function installRaf(): RafController {
  let nextId = 1;
  const callbacks = new Map<number, FrameRequestCallback>();

  Object.defineProperty(window, 'requestAnimationFrame', {
    configurable: true,
    writable: true,
    value: (cb: FrameRequestCallback): number => {
      const id = nextId++;
      callbacks.set(id, cb);
      return id;
    },
  });
  Object.defineProperty(window, 'cancelAnimationFrame', {
    configurable: true,
    writable: true,
    value: (id: number): void => {
      callbacks.delete(id);
    },
  });

  return {
    flushOne() {
      const entry = callbacks.entries().next();
      if (entry.done) return;
      const [id, cb] = entry.value;
      callbacks.delete(id);
      cb(performance.now());
    },
    pending() {
      return callbacks.size;
    },
  };
}

// ---------------------------------------------------------------------------
// Canvas 2d context spy
// ---------------------------------------------------------------------------

export type Canvas2dSpy = {
  clearRect: ReturnType<typeof vi.fn>;
  beginPath: ReturnType<typeof vi.fn>;
  arc: ReturnType<typeof vi.fn>;
  fill: ReturnType<typeof vi.fn>;
  fillStyle: string;
};

// Stub HTMLCanvasElement.getContext('2d') with a spy 2d context. jsdom returns null,
// which would make main.js bail at `if (!ctx) return;`. Returns the spy so a test can
// assert lifecycle CALLS (clearRect/beginPath/arc/fill) — never pixel output.
export function installCanvas2dContext(): Canvas2dSpy {
  const spy: Canvas2dSpy = {
    clearRect: vi.fn(),
    beginPath: vi.fn(),
    arc: vi.fn(),
    fill: vi.fn(),
    fillStyle: '',
  };
  Object.defineProperty(HTMLCanvasElement.prototype, 'getContext', {
    configurable: true,
    writable: true,
    value: vi.fn((type: string) => (type === '2d' ? spy : null)),
  });
  return spy;
}

// ---------------------------------------------------------------------------
// document.hidden / visibilitychange driver
// ---------------------------------------------------------------------------

// Set document.hidden. jsdom does not let the tab go hidden on its own, so the
// visibilitychange handler in main.js is only reachable via this + dispatchVisibilityChange.
export function setDocumentHidden(value: boolean): void {
  Object.defineProperty(document, 'hidden', {
    configurable: true,
    get: () => value,
  });
}

// Dispatch a synthetic visibilitychange event. The real browser fires this on tab
// switches; jsdom never does, so the pause/resume path is characterizable only here.
export function dispatchVisibilityChange(): void {
  document.dispatchEvent(new Event('visibilitychange'));
}

// ---------------------------------------------------------------------------
// Reset
// ---------------------------------------------------------------------------

// Tear down every harness-installed global and registry. Called by setup before/after
// each test so no fake leaks across tests. INVARIANT: this must remove anything the
// installers add (matchMedia, IntersectionObserver, rAF/cAF, getContext, document.hidden).
export function resetHarnessGlobals(): void {
  Reflect.deleteProperty(window, 'matchMedia');
  Reflect.deleteProperty(window, 'IntersectionObserver');
  Reflect.deleteProperty(globalThis as unknown as Record<string, unknown>, 'IntersectionObserver');
  Reflect.deleteProperty(window, 'requestAnimationFrame');
  Reflect.deleteProperty(window, 'cancelAnimationFrame');
  Reflect.deleteProperty(HTMLCanvasElement.prototype, 'getContext');
  // Restore document.hidden to a plain false value owned by the test harness.
  Object.defineProperty(document, 'hidden', {
    configurable: true,
    get: () => false,
  });
  intersectionObservers.length = 0;
  lastMediaQueryList = null;
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

export interface BootOptions {
  // 'loading' makes main.js wait for DOMContentLoaded (which bootMain then dispatches);
  // 'complete' makes it call init() synchronously on import. Default: 'complete'.
  readyState?: DocumentReadyState;
}

// Boot the compiled website module against the already-mounted DOM.
//
// CONTRACT:
//  1. Mount your fixture DOM (via fixtures/ loaders) and install whichever fakes the
//     test needs BEFORE calling bootMain. bootMain installs NO fakes itself.
//  2. bootMain sets document.readyState, then fresh-imports web/scripts/main.js.
//
// Fresh boot is achieved with vi.resetModules() + dynamic import(): the compiled module
// has module-level side effects (it self-runs init()), and a second import in the same
// process returns the cached instance WITHOUT re-running init(). resetModules clears that
// cache so each call re-evaluates the module against the current DOM.
export async function bootMain(opts: BootOptions = {}): Promise<void> {
  const readyState = opts.readyState ?? 'complete';
  Object.defineProperty(document, 'readyState', {
    configurable: true,
    get: () => readyState,
  });

  vi.resetModules();
  await import(/* @vite-ignore */ COMPILED_MAIN);

  // When readyState was 'loading', main.js registered a DOMContentLoaded listener
  // instead of calling init() — fire it so init() runs against the fixture DOM.
  if (readyState === 'loading') {
    document.dispatchEvent(new Event('DOMContentLoaded'));
  }
}
