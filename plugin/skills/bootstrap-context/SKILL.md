---
name: bootstrap-context
description: >-
  Analyze project artifacts and generate a populated CONTEXT.md (or CONTEXT-MAP.md and multiple CONTEXT.md files for
  multi-context repos) with domain terms extracted from existing code, documentation, and
  configuration. Independently invocable or called by setup-project as a final step.
allowed-tools:
  - Read
  - Write
  - Bash(git rev-parse *)
  - Bash(find *)
  - Bash(ls *)
  - Bash(wc *)
  - Bash(jq *)
  - Bash(test *)
  - Bash(basename *)
  - Bash(grep *)
shell: bash
---

## Quick Reference

Rules: `REPORT-01` (blocked report contract)

Before:
- [ ] Project root resolved via `git rev-parse --show-toplevel`
- [ ] No existing CONTEXT.md or CONTEXT-MAP.md at project root
- [ ] At least one project artifact readable (README.md, CLAUDE.md, package manifest, or source files)

After:
- [ ] CONTEXT.md or CONTEXT-MAP.md created following canonical format
- [ ] Terms extracted from actual project artifacts, not invented
- [ ] General programming terms excluded per CONTEXT-FORMAT.md Rules

# Bootstrap Context

Analyze a project's existing artifacts and generate a populated domain glossary following the canonical format defined in `${CLAUDE_PLUGIN_ROOT}/skills/plan-interrogation/references/CONTEXT-FORMAT.md`.

## When to Use

- New project adopting the agent-framework plugin (called by setup-project)
- Existing project that lacks a CONTEXT.md
- User wants to regenerate context from scratch (delete existing file first)

## Required Inputs

None. Operates on the current project root resolved via `git rev-parse --show-toplevel`.

## Procedure

1. Resolve project root via `git rev-parse --show-toplevel`. Stop blocked if not a git repository.

2. **Skip guard:** Check for existing context files at the project root.
   - If `<project root>/CONTEXT.md` exists: report `status: skipped`, `reason: CONTEXT.md already exists` and stop.
   - If `<project root>/CONTEXT-MAP.md` exists: report `status: skipped`, `reason: CONTEXT-MAP.md already exists` and stop.

3. **Resolve project name:** Try in order:
   a. `jq -r '.name // empty' package.json 2>/dev/null`
   b. First `# ` heading in `README.md`
   c. `basename` of project root directory, with hyphens/underscores replaced by spaces, title-cased

4. **Multi-context detection:** Scan for top-level directories that indicate bounded contexts: `services/`, `packages/`, `apps/`, `modules/`, `libs/`, `crates/`, `workspaces/`. For each found, check if it contains 2+ subdirectories with source files. If 2+ bounded context directories are detected, set `multi_context: true`. Otherwise `multi_context: false`.

5. **Artifact discovery:** Read the following files if they exist (first 200 lines each to stay within budget):
   a. `CLAUDE.md` — project rules, architecture, conventions
   b. `AGENT.md` or `AGENTS.md` — agent instructions
   c. `README.md` — project description, key concepts
   d. `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod` — project name, deps
   e. Top-level directory listing (`ls -1`)
   f. Source file names in key directories (use `find . -maxdepth 3 -name '*.ts' -o -name '*.tsx' -o -name '*.py' -o -name '*.go' -o -name '*.rs' -o -name '*.java' -o -name '*.cs' -o -name '*.rb' | head -100`)
   g. Grep for domain type declarations: `grep -rn 'class \|interface \|type \|enum \|struct \|trait \|model \|schema ' --include='*.ts' --include='*.py' --include='*.go' --include='*.rs' --include='*.java' --include='*.cs' --include='*.rb' -l | head -50` — capture filenames only, then read first 5 lines of each match for the declaration name

6. **Term extraction:** From the artifacts gathered in step 5, identify domain-specific terms. Apply these filters:
   - **Include:** Terms that represent concepts unique to this project's domain — entities, aggregates, value objects, domain events, bounded context names, business rules, workflows
   - **Exclude:** General programming terms — controller, service, repository, handler, middleware, util, helper, config, error, response, request, manager, factory, provider, adapter, wrapper, base, abstract, interface (the keyword), type (the keyword), enum (the keyword), model (the keyword when used generically)
   - **Group:** When natural clusters emerge (3+ related terms), organize under subheadings
   - For each term: write a one-sentence definition based on how it's used in the project artifacts. Add `_Avoid_:` aliases if synonyms are evident.

7. **Relationship extraction:** From the artifacts, identify relationships between extracted terms. Express cardinality where obvious (one-to-many, belongs-to, produces, consumes, etc.).

8. **Generate output file(s):**

   **If `multi_context: false`:**
   Create `<project root>/CONTEXT.md` following the format in `${CLAUDE_PLUGIN_ROOT}/skills/plan-interrogation/references/CONTEXT-FORMAT.md`:
   ```
   # {Project Name}

   {One sentence description derived from README or CLAUDE.md}

   ## Language

   {Extracted terms with definitions and Avoid lists}

   ## Relationships

   {Extracted relationships between terms}

   ## Example dialogue

   > **Dev:** "{A realistic question using 2-3 of the extracted terms}"
   > **Domain expert:** "{A clarifying answer that demonstrates term boundaries}"

   ## Flagged ambiguities

   {Any terms that appeared with multiple meanings in the artifacts, or "None detected during bootstrap — use `agent-framework:plan-interrogation` to refine."}
   ```

   **If `multi_context: true`:**
   Create `<project root>/CONTEXT-MAP.md` listing each bounded context with a relative path to its CONTEXT.md. Create a `CONTEXT.md` inside each bounded context directory with terms relevant to that context. Cap at 20 contexts.

9. Report output.

## Term Quality Rules

Per `${CLAUDE_PLUGIN_ROOT}/skills/plan-interrogation/references/CONTEXT-FORMAT.md` (Rules):
- Be opinionated: pick one term, list others as aliases to avoid
- Keep definitions tight: one sentence, define what it IS not what it does
- Only include terms specific to this project's context
- Group under subheadings when natural clusters emerge
- Write a realistic example dialogue using the extracted terms

## Do Not

- Modify existing files (only create new CONTEXT.md / CONTEXT-MAP.md)
- Create files if CONTEXT.md or CONTEXT-MAP.md already exists
- Invent domain terms not evidenced in project artifacts
- Include general programming concepts as terms
- Read full source file contents — use structural signals (filenames, declarations, grep) only
- Commit, push, or touch git state
- Exceed 20 bounded contexts in multi-context mode

## Output

```text
status: complete | skipped | blocked
reason: <text>  # when skipped or blocked

project_root:
- [absolute path]

project_name:
- [resolved name]

multi_context:
- [true | false]

files_created:
- [list of created files]

terms_extracted:
- [count]

term_sources:
- [list of artifact files that contributed terms]

recommendation: "Run `agent-framework:plan-interrogation` to refine and expand this glossary."
```

Use the blocked report contract from `${CLAUDE_PLUGIN_ROOT}/governance/communication-policy.md` for blocked states.
