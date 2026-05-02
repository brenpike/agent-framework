# Scope Policy

## Purpose

Defines explicit file-scope enforcement and accessibility ownership boundaries for all modifying agents.

## Explicit Scope Rule

Any modifying agent must work only in explicitly assigned files.

If another file is required:

1. stop
2. report the exact file
3. explain why it is needed
4. wait for orchestrator reassignment

No agent may silently expand scope.

For mixed presentation-and-behavior files, default owner is `coder`. Designer is the owner when both:

(a) the assignment names files matching one of:
- stylesheet/token files: `*.css`, `*.scss`, `*.sass`, `*.less`, `*.module.css`, `*.style.*`, or files inside directories named `styles/`, `tokens/`, or `theme/`
- markup/component files: `*.html`, `*.htm`, `*.svg`, `*.vue`, `*.svelte`, `*.astro`, `*.mdx`, `*.jsx`, `*.tsx`

(b) the orchestrator's delegation states one of:
- "Do not modify behavior, state, handlers, imports, or non-style logic." (for stylesheet/token files), OR
- "Modify only presentational markup, semantic tags, accessibility attributes (`role`, `aria-*`, `tabindex`, `lang`, `alt`, `title`, `for`/`id` linkages), `className`/`class` values, inline style attributes, and visual ordering of existing elements. Do not modify state, event handlers, imports, props, hooks, business logic, data flow, or runtime behavior." (for markup/component files)

## Accessibility Ownership Split

Designer owns static/presentational accessibility:

- semantic structure
- static ARIA attributes
- accessible labels
- contrast
- visible focus treatment
- touch target sizing
- non-color-only communication
- visual treatment of loading, empty, error, disabled, hover, focus, and active states

Coder owns runtime accessibility:

- state derivation and transitions
- keyboard behavior driven by runtime state
- focus movement driven by application state
- live-region behavior
- accessibility behavior tied to business logic or app state
