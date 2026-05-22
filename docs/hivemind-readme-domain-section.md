# Hivemind README — Domain Language Section (Draft)

This is the planned content for the domain language section of README.md. It serves as both informational reference and branding.

---

## The Swarm

Hivemind is a multi-agent orchestration framework for Claude Code. It coordinates specialized bioforms to plan, build, review, and ship code — so you don't have to manage the pipeline yourself.

### Know Your Bioforms

| Bioform | Role | What it does |
|---|---|---|
| 🧠 **Cerebrate** | Commander | The control plane. Directs the swarm, manages git lifecycle, never writes code. Your main interface. |
| 👁️ **Overlord** | Scanner | Scouts the problem space. Returns a **psionic map** — the plan of attack. Read-only; reports but never modifies. |
| 🔨 **Drone** | Builder | Builds code within its assigned scope. The workhorse of the swarm. |
| 🎭 **Changeling** | Shaper | Handles UI, styling, and visual presentation. Reshapes how things look and feel. |

### The Lifecycle

```
You ──→ Cerebrate ──→ Overlord (scout) ──→ Psionic Map
                  ──→ Drone/Changeling (build) ──→ Essence
                  ──→ Adaptation Cycle (review) ──→ PR
```

1. You give the **cerebrate** a task
2. The **overlord** scans the territory and returns a **psionic map**
3. The cerebrate **spawns** specialists (**drones** / **changelings**) phase by phase
4. Each phase produces **essence** — knowledge carried forward
5. An **adaptation cycle** reviews the work before shipping
6. A PR is opened when the swarm stabilizes

### Brood Mode — Parallel Execution

When the work is big enough, the cerebrate can split it into independent **strains** and dispatch a **brood** — multiple parallel sessions, each running its own full lifecycle in a separate git worktree.

```
You ──→ Cerebrate ──→ Overlord (decompose)
                  ──→ "3 independent strains detected. Deploy brood?" 
                  ──→ Yes ──→ Hatchery mode
                            ──→ Strain A (tmux tab) ──→ own branch, own PR
                            ──→ Strain B (tmux tab) ──→ own branch, own PR  
                            ──→ Strain C (tmux tab) ──→ own branch, own PR
```

The cerebrate enters **hatchery** mode — monitoring the brood from home base while each strain evolves independently.

### Signals

| Signal | Meaning |
|---|---|
| 🔥 **Flare** | Urgent — agent hit something it can't resolve alone. Cerebrate stops and asks you. |
| ⚡ **Reflex** | Simple task — cerebrate skips the overlord and spawns a drone directly. |
| 🧬 **Mutation Decay** | Two fixes are fighting each other. Swarm stops. You decide. |
| 🔄 **Adaptation Cycle** | Review in progress — the swarm is stabilizing before shipping. |

### Plain English Still Works

Every themed term maps to a plain concept. You don't need to learn the language to use the framework:

| You can say... | Or say... | Same thing |
|---|---|---|
| "checkpoint commit" | "molt" | Save progress at a phase boundary |
| "dispatch a fleet" | "spawn a brood" | Run parallel sessions |
| "what's the status" | "brood status" | Check progress across sessions |
| "plan this" | "send the overlord" | Get a plan before building |

The theme is for fun. The framework works with or without it.
