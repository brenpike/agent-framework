/**
 * Hivemind website — main.ts
 * Single-file motion module. No internal imports.
 *
 * Responsibilities:
 *  1. Mobile nav toggle (aria-expanded / aria-hidden sync, Escape, link click close)
 *  2. Scroll-reveal via IntersectionObserver (progressive enhancement — no hidden content if JS absent)
 *  3. Glow / pulse stagger on .js-glow-target elements
 *  4. Swarm particle canvas (decorative, aria-hidden, pointer-events:none, pauses when hidden/offscreen)
 *
 * prefers-reduced-motion:
 *  CSS layer: @media block in main.css (kills transitions/animations)
 *  JS layer:  reducedMotion flag gates all JS-driven motion. Responds live to change.
 */

// ---------------------------------------------------------------------------
// Reduced-motion gate
// ---------------------------------------------------------------------------

const motionQuery: MediaQueryList = window.matchMedia(
  '(prefers-reduced-motion: reduce)'
);

function prefersReducedMotion(): boolean {
  return motionQuery.matches;
}

// Older Safari/WebKit MediaQueryList does not inherit EventTarget and lacks
// addEventListener; fall back to the deprecated addListener so init() does not
// throw and abort later modules.
type LegacyMediaQueryList = MediaQueryList & {
  addListener?: (listener: (e: MediaQueryListEvent) => void) => void;
};

function onMotionChange(listener: (e: MediaQueryListEvent) => void): void {
  if (typeof motionQuery.addEventListener === 'function') {
    motionQuery.addEventListener('change', listener);
  } else {
    (motionQuery as LegacyMediaQueryList).addListener?.(listener);
  }
}

// ---------------------------------------------------------------------------
// 1. Mobile nav toggle
// ---------------------------------------------------------------------------

function initNavToggle(): void {
  const toggle = document.getElementById('nav-toggle');
  const nav    = document.querySelector<HTMLElement>('.site-nav');
  const drawer = document.getElementById('nav-drawer');

  if (!toggle || !nav || !drawer) return;

  function openNav(): void {
    nav!.setAttribute('data-nav-open', '');
    toggle!.setAttribute('aria-expanded', 'true');
    drawer!.setAttribute('aria-hidden', 'false');
  }

  function closeNav(): void {
    nav!.removeAttribute('data-nav-open');
    toggle!.setAttribute('aria-expanded', 'false');
    drawer!.setAttribute('aria-hidden', 'true');
  }

  function isOpen(): boolean {
    return nav!.hasAttribute('data-nav-open');
  }

  toggle.addEventListener('click', () => {
    if (isOpen()) {
      closeNav();
      toggle.focus();
    } else {
      openNav();
    }
  });

  // Close on any nav link click inside the drawer
  drawer.querySelectorAll<HTMLAnchorElement>('.site-nav__link').forEach((link) => {
    link.addEventListener('click', () => {
      closeNav();
      toggle.focus();
    });
  });

  // Close on Escape
  document.addEventListener('keydown', (e: KeyboardEvent) => {
    if (e.key === 'Escape' && isOpen()) {
      closeNav();
      toggle.focus();
    }
  });
}

// ---------------------------------------------------------------------------
// 2. Scroll-reveal (IntersectionObserver, progressive enhancement)
// ---------------------------------------------------------------------------

function initScrollReveal(): void {
  // Progressive enhancement: if IntersectionObserver is absent or reduced-motion
  // is on, ensure all elements are visible immediately (no transform/opacity hide).
  const elements = document.querySelectorAll<HTMLElement>('.js-scroll-reveal');

  if (prefersReducedMotion() || !('IntersectionObserver' in window)) {
    // Guarantee visibility — CSS .is-revealed state makes them visible;
    // apply it now so they're never stuck in the "waiting" hidden state.
    elements.forEach((el) => {
      el.classList.add('is-revealed');
    });
    return;
  }

  // Set initial "waiting" state — CSS transitions from this
  elements.forEach((el) => {
    el.classList.add('reveal-pending');
  });

  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        const el = entry.target as HTMLElement;
        const delayMs = parseInt(el.dataset['delay'] ?? '0', 10);
        setTimeout(() => {
          el.classList.remove('reveal-pending');
          el.classList.add('is-revealed');
        }, isNaN(delayMs) ? 0 : delayMs);
        observer.unobserve(el);
      });
    },
    { threshold: 0.12, rootMargin: '0px 0px -40px 0px' }
  );

  elements.forEach((el) => observer.observe(el));

  // If reduced-motion preference changes live, immediately reveal remaining elements
  onMotionChange(() => {
    if (prefersReducedMotion()) {
      elements.forEach((el) => {
        el.classList.remove('reveal-pending');
        el.classList.add('is-revealed');
      });
    }
  });
}

// ---------------------------------------------------------------------------
// 3. Glow / pulse stagger on .js-glow-target
// ---------------------------------------------------------------------------

function initGlowTargets(): void {
  if (prefersReducedMotion()) return;

  const targets = document.querySelectorAll<HTMLElement>('.js-glow-target');

  targets.forEach((el, i) => {
    const glowColor = el.dataset['glow'] ?? 'violet';
    // Stagger the animation-delay so targets don't all pulse in sync
    el.style.animationDelay = `${i * 0.6}s`;
    el.classList.add(`pulse-${glowColor}`);
  });

  // Also pulse the nav logo
  const logo = document.getElementById('nav-logo-glow');
  if (logo) {
    logo.classList.add('nav-logo-pulse');
  }

  // Respond to live preference change
  onMotionChange(() => {
    if (prefersReducedMotion()) {
      targets.forEach((el) => {
        const glowColor = el.dataset['glow'] ?? 'violet';
        el.classList.remove(`pulse-${glowColor}`);
        el.style.animationDelay = '';
      });
      if (logo) logo.classList.remove('nav-logo-pulse');
    }
  });
}

// ---------------------------------------------------------------------------
// 4. Swarm particle canvas
// ---------------------------------------------------------------------------

interface Particle {
  x: number;
  y: number;
  vx: number;
  vy: number;
  radius: number;
  color: string;
  alpha: number;
  alphaTarget: number;
  alphaDelta: number;
  pulseSpeed: number;
}

// Accent colors from the design tokens — pure CSS vars can't be read before
// render, so we mirror the hex values here.
const SWARM_COLORS: string[] = [
  'rgba(57, 255, 20,',   // spore green
  'rgba(139, 92, 246,',  // violet
  'rgba(0, 255, 240,',   // cyan
  'rgba(255, 45, 155,',  // magenta
];

function randomBetween(min: number, max: number): number {
  return min + Math.random() * (max - min);
}

function createParticle(canvasWidth: number, canvasHeight: number): Particle {
  const baseAlpha = randomBetween(0.04, 0.18);
  return {
    x: randomBetween(0, canvasWidth),
    y: randomBetween(0, canvasHeight),
    vx: randomBetween(-0.18, 0.18),
    vy: randomBetween(-0.12, 0.12),
    radius: randomBetween(1.5, 4),
    color: SWARM_COLORS[Math.floor(Math.random() * SWARM_COLORS.length)],
    alpha: baseAlpha,
    alphaTarget: baseAlpha,
    alphaDelta: randomBetween(0.0003, 0.001),
    pulseSpeed: randomBetween(0.002, 0.006),
  };
}

function initSwarmCanvas(): void {
  // Only create canvas on hero sections that exist on this page
  const heroSection = document.getElementById('hero')
    ?? document.getElementById('func-hero')
    ?? document.getElementById('ben-hero');

  if (!heroSection) return;
  if (prefersReducedMotion()) return;

  const canvas = document.createElement('canvas');
  canvas.setAttribute('aria-hidden', 'true');
  canvas.style.cssText = [
    'position:absolute',
    'inset:0',
    'width:100%',
    'height:100%',
    'pointer-events:none',
    'z-index:0',
  ].join(';');

  // Ensure hero section is positioned so absolute canvas is contained
  const heroStyle = window.getComputedStyle(heroSection);
  if (heroStyle.position === 'static') {
    heroSection.style.position = 'relative';
  }

  heroSection.prepend(canvas);

  const ctx = canvas.getContext('2d');
  if (!ctx) return;

  // Cap particle count — scale slightly with viewport area
  const MAX_PARTICLES = 60;

  let particles: Particle[] = [];
  let rafId: number | null = null;
  let isRunning = false;
  let tabHidden = false;

  function resize(): void {
    canvas.width  = heroSection!.offsetWidth;
    canvas.height = heroSection!.offsetHeight;
  }

  function buildParticles(): void {
    const count = Math.min(
      MAX_PARTICLES,
      Math.round((canvas.width * canvas.height) / 14000)
    );
    particles = Array.from({ length: count }, () =>
      createParticle(canvas.width, canvas.height)
    );
  }

  function tick(): void {
    if (!isRunning) return;
    ctx!.clearRect(0, 0, canvas.width, canvas.height);

    particles.forEach((p) => {
      // Drift
      p.x += p.vx;
      p.y += p.vy;

      // Wrap at edges
      if (p.x < -p.radius)           p.x = canvas.width  + p.radius;
      if (p.x > canvas.width + p.radius)  p.x = -p.radius;
      if (p.y < -p.radius)           p.y = canvas.height + p.radius;
      if (p.y > canvas.height + p.radius) p.y = -p.radius;

      // Alpha pulse (breathe)
      p.alpha += p.alphaDelta;
      if (p.alpha > 0.22 || p.alpha < 0.02) {
        p.alphaDelta = -p.alphaDelta;
        p.alpha = Math.max(0.02, Math.min(0.22, p.alpha));
      }

      ctx!.beginPath();
      ctx!.arc(p.x, p.y, p.radius, 0, Math.PI * 2);
      ctx!.fillStyle = `${p.color} ${p.alpha.toFixed(3)})`;
      ctx!.fill();
    });

    rafId = requestAnimationFrame(tick);
  }

  function start(): void {
    if (isRunning) return;
    isRunning = true;
    tick();
  }

  function stop(): void {
    isRunning = false;
    if (rafId !== null) {
      cancelAnimationFrame(rafId);
      rafId = null;
    }
  }

  // Pause when tab is hidden
  document.addEventListener('visibilitychange', () => {
    tabHidden = document.hidden;
    if (tabHidden) {
      stop();
    } else if (!prefersReducedMotion()) {
      start();
    }
  });

  // Pause when canvas scrolls entirely offscreen (IntersectionObserver)
  if ('IntersectionObserver' in window) {
    const canvasObserver = new IntersectionObserver(
      (entries) => {
        const visible = entries[0]?.isIntersecting ?? false;
        if (visible && !tabHidden && !prefersReducedMotion()) {
          start();
        } else {
          stop();
        }
      },
      { threshold: 0 }
    );
    canvasObserver.observe(canvas);
  } else {
    start();
  }

  // Live reduced-motion change
  onMotionChange(() => {
    if (prefersReducedMotion()) {
      stop();
      ctx!.clearRect(0, 0, canvas.width, canvas.height);
    } else if (!tabHidden) {
      start();
    }
  });

  resize();
  buildParticles();

  // Resize handler — debounced
  let resizeTimer: ReturnType<typeof setTimeout> | null = null;
  window.addEventListener('resize', () => {
    if (resizeTimer !== null) clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      stop();
      resize();
      buildParticles();
      if (!tabHidden && !prefersReducedMotion()) start();
    }, 150);
  });
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

function init(): void {
  initNavToggle();
  initScrollReveal();
  initGlowTargets();
  initSwarmCanvas();
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
