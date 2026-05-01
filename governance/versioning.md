# Versioning Policy

## Purpose

Generic SemVer workflow for repositories that publish versioned artifacts.

Project-specific package names, artifact paths, version-file locations, changelog locations, tag prefixes, and validation commands live in `CLAUDE.md` or project docs referenced by `CLAUDE.md`.

## Scope

Applies to every independently versioned artifact defined by the project: packages, libraries, applications, plugins, containers, distributable binaries, or similar artifacts.

Each artifact is versioned independently unless project documentation says otherwise.

Internal shared components with no standalone distribution carry no version unless the project defines one. Changes to shared components may require bumps in dependent artifacts if public API, runtime behavior, generated output, package contents, or compatibility contracts change.

## SemVer Rules

This repository follows Semantic Versioning 2.0.0.

Format: `MAJOR.MINOR.PATCH`

| Increment | Trigger |
|---|---|
| MAJOR | Breaking change to public API, compatibility contract, data format, runtime behavior contract, or documented consumer expectation |
| MINOR | Backward-compatible public API, capability, option, behavior, or artifact surface |
| PATCH | Bug fix, internal refactor, or implementation change with no public compatibility impact |

For `0.x.y` artifacts, SemVer permits minor increments for breaking changes. Breaking changes must still include a changelog entry under `Changed` or `Removed` that names the breaking surface (function, type, flag, file, endpoint) and the migration path.

Pre-release labels such as `1.2.0-beta.1` require orchestrator coordination and project release-workflow support.

## Bump Trigger

A version bump is required when a PR changes files that affect a published artifact's:

- runtime behavior
- public API
- compatibility contract
- generated output
- packaged output
- distribution metadata
- documented consumer expectation

Exact bump-trigger paths are project-specific and must be defined in `CLAUDE.md` or referenced project documentation.

No bump is required by default for:

- documentation-only changes
- test-only changes
- CI-only changes
- agent framework/governance changes
- changelog-only maintenance
- markdown-only changes

Project documentation may define additional required or excluded paths. When `CLAUDE.md` does not define bump-trigger paths, this section's lists are exhaustive: any change matching the bullets above triggers a bump; any change matching the "No bump is required by default" list does not.

## Bump Type Determination

The orchestrator determines bump type from:

1. conventional commit type(s)
2. public API, compatibility, runtime, data format, generated output, package, or documented behavior impact
3. breaking-change markers such as `!`, `BREAKING CHANGE:`, or actual compatibility impact

| Commit / impact | Increment |
|---|---|
| `feat` with backward-compatible public capability | MINOR |
| `feat!` or `BREAKING CHANGE:` | MAJOR |
| `fix` / `bugfix` without breaking change | PATCH |
| `refactor` without public compatibility impact | PATCH |
| `refactor!` | MAJOR |
| `chore` / `docs` / `test` / `ci` without artifact impact | No bump |

Ask the user before delegating version edits when the change matches more than one row of the table above, OR matches no row.

A change "matches a row" when both:

- the dominant Bump Type Determination row across all commits on the working branch since it diverged from `<base>` equals the row in question, AND
- the row's impact condition is satisfied:
  - for the MAJOR, MINOR, and PATCH rows: at least one bullet in Bump Trigger above is satisfied by the change
  - for the No-bump row: the change matches one or more bullets in the "No bump is required by default" list above and matches no bullet in Bump Trigger

To compute the dominant row: read each commit's full subject and body via `git log --format='%H%n%s%n%b%n--END--' <base>..HEAD`, where `<base>` is the resolved base branch from `${CLAUDE_PLUGIN_ROOT}/governance/branching-pr-workflow.md` (Required Git Preflight). For each commit:

1. If the subject contains `!` immediately before `:` (e.g., `feat!:`, `refactor!:`), map the commit to the MAJOR row regardless of subject type.
2. Else if any line of the subject or body matches `^BREAKING CHANGE:` or `^BREAKING-CHANGE:`, map the commit to the MAJOR row regardless of subject type.
3. Else parse the leading token before `(` or `:` in the subject and map by type: `feat` → MINOR; `fix` and `bugfix` → PATCH; `refactor` → PATCH; `chore`, `docs`, `test`, `ci` → No-bump.

Determine the dominant row with this precedence:

1. **MAJOR precedence**: if any commit maps to the MAJOR row, the dominant row is MAJOR. Breaking changes are never overridden by majority count of non-breaking commits.
2. Otherwise, count commits per remaining row. The dominant row is the row with the highest count.
3. If the working branch has exactly one commit beyond `<base>`, that commit's row is the dominant row.
4. If two or more rows (other than MAJOR) tie for the highest count, the change matches more than one row.
5. If no commit's mapping resolves to a recognized row, the change matches no row.

Note: multiple commit types that map to the same row do not produce a tie. Example: a branch with one `docs:` commit and one `test:` commit has two commits in the No-bump row and is a single-row match (No bump), not a multi-row escalation.

## Bump Execution

The orchestrator delegates version/release file edits to coder.

A bump is included in the same PR as the triggering change unless the user explicitly directs otherwise.

Project-specific documentation must define the exact files to update atomically, such as:

- canonical version file
- changelog/release notes
- package/artifact metadata
- documentation mirrors
- release validation files

Every artifact must have one canonical version source. Mirrors are informational and must be kept in sync.

If `CLAUDE.md` does not list the artifact files for a triggered bump, the orchestrator stops and asks the user before delegating any version edit. The coder must not infer artifact files.

## CHANGELOG / Release Notes

Each versioned artifact must maintain release notes or a changelog unless `CLAUDE.md` defines a different release documentation mechanism.

Recommended sections follow Keep a Changelog:

- Added
- Changed
- Deprecated
- Removed
- Fixed
- Security

When bumping, convert pending unreleased entries into a dated release section. If `CLAUDE.md` does not specify how to reset the unreleased section, reset it to:

```markdown
## [Unreleased]

### Added

### Changed

### Fixed
```

## Tags

Tags are created according to the project release workflow.

Project documentation must define:

- manual vs CI-created tags
- tag format
- prefix per artifact when multiple artifacts exist
- annotated vs lightweight
- timing relative to publish/deploy

Recommended generic formats:

- single artifact: `vX.Y.Z`
- multiple artifacts: `<artifact-prefix>/vX.Y.Z`

## Agent Rules

- Orchestrator owns bump detection and bump type decisions.
- Planner may recommend versioning implications but must not edit files.
- Coder may edit version/release files only when explicitly delegated.
- Designer never edits version/release files unless a purely presentational documentation file is explicitly assigned.
- If project-specific version paths or canonical version source are unclear, stop and ask the user.
