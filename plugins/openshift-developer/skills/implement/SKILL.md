---
name: implement
description: Implement a fix for a JIRA issue — analyze the codebase, write code, add tests, and commit. Does not create PRs or run reviews. Use as a sub-skill of solve or standalone for code-only changes.
---

## Name
openshift-developer:implement

## Synopsis
```text
/openshift-developer:implement <jira-issue-id> [remote] [--ci]
```

## Description

Analyzes a JIRA issue, implements a solution in the current repository, and commits the changes. This is the coding agent — it reads the issue, understands the codebase, writes the fix, adds tests, and produces well-structured commits. It does not create PRs or run code reviews; the orchestrator (`/openshift-developer:solve`) handles those.

## Implementation

### Step 1: Issue Analysis

Parse the JIRA issue and fetch details:

1. Use curl to fetch JIRA issue data:
   ```bash
   curl -s -u "$JIRA_USERNAME:$JIRA_API_TOKEN" "https://redhat.atlassian.net/rest/api/3/issue/{$1}"
   ```
2. Parse JSON response to extract:
   - Issue summary and description
   - From within the description expect the following sections:
     - Required: Context, Acceptance criteria
     - Optional: Steps to reproduce (for bugs), Expected vs actual behavior
3. If `--ci` flag (`$3`) is NOT set: Ask the user for further issue grooming if the required sections are missing
4. If `--ci` flag (`$3`) IS set: Proceed with available information, making reasonable assumptions where needed

### Step 2: Codebase Analysis

Search and analyze relevant code:

- Find related files and functions
- Understand current implementation
- Identify areas that need changes
- Use Grep and Glob tools to search for:
  - Related function names mentioned in JIRA
  - File patterns related to the component
  - Similar existing implementations
  - Test files that need updates

### Step 3: Solution Implementation

1. Think hard and create a detailed, step-by-step plan. Save it to `spec-$1.md` within the `.work/solve/` folder (e.g. `.work/solve/spec-OCPBUGS-12345.md`)
2. If `--ci` flag (`$3`) is NOT set: Ask the user to review the plan and give them the choice to modify it before starting
3. If `--ci` flag (`$3`) IS set: Proceed immediately without waiting for approval
4. Implement the plan:
   - Make necessary code changes using Edit/MultiEdit tools
   - Follow existing code patterns and conventions
   - Add or update tests when code behavior changes or new functions are introduced
   - Update documentation if needed within the `docs/` folder
   - If the problem is too complex consider delegating to one of the SME agents
   - Ensure godoc comments are generated for any newly created public functions
     - Use your best judgement if godoc comments are needed for private functions
     - A comment should not be generated for a simple function like `func add(int a, b) int { return a + b }`
   - Create unit tests for any newly created functions

### Step 4: Commit Creation

1. Create feature branch using the jira-key `$1` as the branch name (e.g. `git checkout -b fix-{jira-key}`)
2. Break commits into logical components based on the nature of the changes
3. Each commit must honor https://www.conventionalcommits.org/en/v1.0.0/ and always include a commit message body articulating the "why"
4. Use your judgment to organize commits in a way that makes them easy to review and understand
5. Common logical groupings (use as guidance, not rigid rules):
   - API changes: Changes in `api/` directory (types, CRDs)
     - Example: `git commit -m"feat(api): Update HostedCluster API for X" -m"Add new fields to support Y functionality"`
   - Vendor changes: Dependency updates in `vendor/` directory
     - Example: `git commit -m"chore(vendor): Update dependencies for X" -m"Required to pick up bug fixes in upstream library Y"`
   - Generated code: Auto-generated clients, informers, listers, and CRDs
     - Example: `git commit -m"chore(generated): Regenerate clients and CRDs" -m"Regenerate after API changes to ensure client code is in sync"`
   - CLI changes: User-facing command changes in `cmd/` directory
     - Example: `git commit -m"feat(cli): Add support for X flag" -m"This allows users to configure Y behavior at cluster creation time"`
   - Operator changes: Controller logic in `operator/` or `controllers/`
     - Example: `git commit -m"feat(operator): Implement X controller logic" -m"Without this the controller won't reconcile when Y condition occurs"`
   - Support/utilities: Shared code in `support/` directory
     - Example: `git commit -m"refactor(support): Extract common X utility" -m"Consolidate duplicated logic from multiple controllers into shared helper"`
   - Tests: Test additions or modifications
     - Example: `git commit -m"test: Add tests for X functionality" -m"Ensure the new behavior is covered by unit tests to prevent regressions"`
   - Documentation: Changes in `docs/` directory
     - Example: `git commit -m"docs: Document X feature" -m"Help users understand how to configure and use the new capability"`
6. Push the branch with all commits against the remote specified in argument `$2`

## Arguments
- `$1` — The JIRA issue to solve (required)
- `$2` — The remote repository to push the branch (required)
- `$3` — Optional `--ci` flag for non-interactive CI automation mode. When set, skips all user prompts and proceeds automatically.

## Examples

1. **Implement a fix for a JIRA issue**:
   ```text
   /openshift-developer:implement OCPBUGS-12345 origin --ci
   ```

## Guidelines

- Authentication uses Basic auth with `JIRA_USERNAME` and `JIRA_API_TOKEN` for Atlassian Cloud
- This skill only writes code and commits — it does not create PRs or run reviews
- The orchestrator (`/openshift-developer:solve`) calls this skill as a sub-step
