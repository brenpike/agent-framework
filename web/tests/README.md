# web/tests — Characterization test charter

This suite is a **Feathers-style characterization (pinning) safety net** for the
existing website JavaScript (`web/src/main.ts`, compiled to `web/scripts/main.js`).
Its job is to lock in the *current observable behavior* of the shipped site so a
future refactor can be made with confidence that nothing changed.

## Organizing principle

> Characterization tests describe the software **as it is**, not as it should be.

These tests are a behavior-pinning net, not a correctness spec. They exist to make
a later refactor safe, not to assert the code is "right".

## The rules

1. **Pin CURRENT behavior, never desired behavior.** If the code does something
   surprising, the test pins it *as-is*.
2. **Suspected bugs/quirks are pinned, not fixed.** Annotate them with a
   `// PINNED QUIRK` comment explaining what looks wrong and why we are pinning it
   anyway. A fix is a separate, deliberate change — never a side effect of adding a
   test.
3. **Pin observable contracts only.** Acceptable to assert:
   - classes added/removed (`is-revealed`, `reveal-pending`, `pulse-*`, `nav-logo-pulse`)
   - attributes (`aria-expanded`, `aria-hidden`, `data-nav-open`)
   - presence/absence of the swarm `<canvas>` element
   - canvas 2d-context **lifecycle calls** (`clearRect`, `beginPath`, `arc`, `fill`)
   - which code branch was taken (IO present vs absent, reduced-motion on vs off)
4. **NEVER pin nondeterministic internals.** Off-limits:
   - particle positions, velocities, counts, or radii
   - pixel/numeric canvas output
   - `requestAnimationFrame` timing or frame counts
   - anything seeded by `Math.random()`

## Decision: test the COMPILED artifact

The unit under test is **`web/scripts/main.js`** (the compiled output that the three
HTML pages actually load via `<script type="module" src="./scripts/main.js">`), NOT
the `.ts` source. `web/scripts/` is gitignored, so a fresh checkout has no `main.js`
— you **must** run `npm run build` (tsc) before the tests can import it.

## How to run

```sh
npm run build && npm test
```

`npm run build` compiles `web/src/main.ts` → `web/scripts/main.js`.
`npm test` runs Vitest (jsdom environment) against the compiled file.

## jsdom divergences from a real browser (documented, do NOT fight)

These are points where jsdom does not behave like a real browser. Tests must account
for them rather than try to force real-browser behavior:

- **`window.matchMedia` does not exist in jsdom.** `main.js` reads it at module-eval
  time (top-level `const motionQuery = window.matchMedia(...)`). The fake MUST be
  installed *before* the module is imported, or the import throws.
- **`IntersectionObserver` is not provided by jsdom.** The fake is controllable: its
  callback can be invoked manually with synthetic entries, and it can be deleted from
  the global to exercise the code's `'IntersectionObserver' in window` absent branch.
- **`requestAnimationFrame` / `cancelAnimationFrame` are unreliable in jsdom.** The
  harness provides fakes. NOTE: Vitest's `vi.useFakeTimers()` does NOT fake rAF/cAF by
  default — a test using fake timers that needs rAF must opt in:
  `vi.useFakeTimers({ toFake: ['requestAnimationFrame', 'cancelAnimationFrame', 'setTimeout', ...] })`.
- **`HTMLCanvasElement.getContext('2d')` returns `null` in jsdom.** The harness stubs
  it with a spy 2d context exposing `clearRect`, `beginPath`, `arc`, `fill`,
  `fillStyle`, etc. Assert *calls*, never pixel output.
- **`visibilitychange` does not auto-fire in jsdom.** Set `document.hidden` via the
  helper (`Object.defineProperty`) and dispatch a synthetic `visibilitychange` event
  manually. The pause/resume handler is characterizable ONLY by manual dispatch.
- **`window.getComputedStyle(el).position` returns `''` (empty string) in jsdom, NOT
  `'static'`.** Therefore the swarm-canvas `if (heroStyle.position === 'static')`
  branch in `initSwarmCanvas` does **not** fire under default jsdom. Document this and
  do not try to force it — pin the behavior that actually occurs.

## Uncharacterized — requires a real browser (deferred)

jsdom cannot honestly test these; they are explicitly out of scope for this suite:

1. **Canvas actual rendering / animation** — pixels, frame loop visuals, particle motion.
2. **Real `visibilitychange` firing** — the browser firing it on real tab switches.
3. **Real `IntersectionObserver` geometry/threshold** on actual scroll position.

## PLAYWRIGHT TRIPWIRE

Add a Playwright suite ONLY when a future refactor's scope actually touches
swarm-canvas rendering, the `visibilitychange` pause/resume logic, or the
`IntersectionObserver` wiring. Until then jsdom + manually-driven fakes cover the
logic; real-browser-only API-misuse regressions in those three areas are the sole gap
Playwright would close.

## Harness API (for Phase 2 test authors)

See `web/tests/helpers/boot-main.ts` and `web/tests/fixtures/` for the importable
helpers. The contract:

- `installMatchMedia(opts)` — install the matchMedia fake. `opts.matches` sets the
  reduced-motion preference; `opts.legacy: true` produces a MediaQueryList that
  exposes only `addListener` (no `addEventListener`) to drive the legacy WebKit path.
- `installIntersectionObserver()` — install the controllable IO fake; returns a
  registry of created instances so a test can fire `entries` manually.
- `removeIntersectionObserver()` — delete IO from the global to test the absent branch.
- `installRaf()` — install rAF/cAF fakes (only needed without `vi.useFakeTimers`).
- `installCanvas2dContext()` — stub `getContext('2d')` with a spy context; returns the
  spy so calls can be asserted.
- `setDocumentHidden(value)` / `dispatchVisibilityChange()` — drive the tab-hidden path.
- `bootMain(fixture)` — install nothing on its own; you install the fakes you need
  first, then call `bootMain(...)` which mounts the fixture DOM, sets `readyState`, and
  **fresh-imports** the compiled module (via `vi.resetModules()` + dynamic `import()`)
  so its top-level boot runs against your DOM. Returns once `init()` has run.

**Fresh boot is mandatory per test.** The compiled module has module-level side
effects; importing it twice in one process returns the cached instance and will NOT
re-run `init()`. `bootMain` calls `vi.resetModules()` then `await import(...)` to force
a clean evaluation each time.
