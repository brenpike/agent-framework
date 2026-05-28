# Architecture Language

Shared vocabulary for reasoning about — and acting on — module depth. Use these terms exactly — do not substitute "component," "service," "API," or "boundary." Consistent language is the whole point of this file.

This is **architecture** vocabulary, stable across projects. It is distinct from the project's **`CONTEXT.md`**, which is the project's **domain** glossary (Order, Invoice, Shipment). Name domain concepts using `CONTEXT.md` and name architectural shapes using this file: "the Order intake module is shallow," never "the FooBarHandler is shallow."

## Contents

- [Terms](#terms)
- [Principles](#principles)
- [The deletion test](#the-deletion-test)
- [Relationships](#relationships)
- [Rejected framings](#rejected-framings)

## Terms

**Module**
Anything with an interface and an implementation. Deliberately scale-agnostic — applies equally to a function, a class, a package, or a tier-spanning slice.
_Avoid_: unit, component, service.

**Interface**
Everything a caller must know to use the module correctly. Includes the type signature, but also invariants, ordering constraints, error modes, required configuration, and performance characteristics.
_Avoid_: API, signature — both are too narrow; they refer only to the type-level surface.

**Implementation**
The body of code inside a module. Distinct from **adapter**: a thing can be a small adapter over a large implementation (a Postgres repository) or a large adapter over a small implementation (an in-memory fake). Reach for "adapter" when the seam is the topic; "implementation" otherwise.

**Depth**
Leverage at the interface — the amount of behaviour a caller (or test) can exercise per unit of interface they must learn. A module is **deep** when a large amount of behaviour sits behind a small interface. A module is **shallow** when the interface is nearly as complex as the implementation.

**Seam** _(from Michael Feathers)_
A place where behaviour can be altered without editing in that place. The *location* at which a module's interface lives. Where to put the seam is its own design decision, distinct from what goes behind it.
_Avoid_: boundary — overloaded with DDD's bounded context.

**Adapter**
A concrete thing that satisfies an interface at a seam. Describes *role* (which slot it fills), not substance (what is inside it).

**Leverage**
What callers get from depth: more capability per unit of interface they must learn. One implementation pays back across N call sites and M tests.

**Locality**
What maintainers get from depth: change, bugs, knowledge, and verification concentrate at one place instead of spreading across callers. Fix once, fixed everywhere.

## Principles

- **Depth is a property of the interface, not the implementation.** A deep module can be internally composed of small, mockable, swappable parts — they just are not part of the interface. A module can have **internal seams** (private to its implementation, used by its own tests) as well as an **external seam** at its interface.
- **The interface is the test surface.** Callers and tests cross the same seam. If a test wants to reach *past* the interface, the module is probably the wrong shape.
- **One adapter means a hypothetical seam. Two adapters means a real one.** Do not introduce a seam unless something actually varies across it (typically production + test).

## The deletion test

The primary signal for whether a module is shallow. Imagine deleting the module and inlining its body at every call site:

- If complexity **vanishes**, the module was a pass-through — it was not hiding anything. It is shallow.
- If complexity **reappears across N callers**, the module was earning its keep — it concentrated something. It is deep.

A "yes, complexity reappears across many callers" is the signal that a module is worth deepening rather than deleting.

## Relationships

- A **module** has exactly one **interface** — the surface it presents to callers and tests.
- **Depth** is a property of a **module**, measured against its **interface**.
- A **seam** is where a **module**'s **interface** lives.
- An **adapter** sits at a **seam** and satisfies the **interface**.
- **Depth** produces **leverage** for callers and **locality** for maintainers.

## Rejected framings

- **Depth as the ratio of implementation lines to interface lines** (Ousterhout): rewards padding the implementation. Use depth-as-leverage instead.
- **"Interface" as the TypeScript `interface` keyword or a class's public method list**: too narrow — interface here includes every fact a caller must know.
- **"Boundary"**: overloaded with DDD's bounded context. Say **seam** or **interface**.
