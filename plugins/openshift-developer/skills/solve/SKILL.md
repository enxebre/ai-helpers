---
name: solve
description: End-to-end orchestrator that chains implement → review → fix for a JIRA issue. Dispatches to sub-skills in the same session. Never writes code directly.
---

## Name
openshift-developer:solve

## Synopsis
```text
/openshift-developer:solve <jira-issue-id> [remote] [--ci]
```

## Description

Orchestrates the full solve pipeline for a JIRA issue by dispatching to sub-skills in sequence. Never writes code directly — all coding happens through the implement skill, all review through the code-review skill. Makes decisions about iteration based on review findings.

## Implementation

### Step 1: Implement

Invoke the implement skill to analyze the issue, write the fix, and commit:

```text
/openshift-developer:implement $1 $2 $3
```

After the implement skill completes, check whether code changes were produced:

```bash
git diff --stat HEAD~1 2>/dev/null || echo "no changes"
```

If no code changes were produced, stop and report that no changes were needed.

### Step 2: Review

Invoke the code review skill to review the uncommitted or recently committed changes:

```text
/code-review:pre-commit-review --language go
```

### Step 3: Evaluate findings and iterate

If the review produced no findings, stop — the implementation is complete.

If the review produced findings, invoke the address-review skill to fix them:

```text
/openshift-developer:address-review-precommit
```

After fixing, run the review again (Step 2) to check whether the fixes introduced new issues.

If the second review produces new findings, invoke address-review-precommit one more time. Do not review a third time.

Maximum 2 review+fix cycles. If findings remain after the second fix, note them in the conversation output as known issues.

## Arguments
- `$1` — The JIRA issue to solve (required)
- `$2` — The remote repository to push the branch (required)
- `$3` — Optional `--ci` flag for non-interactive CI automation mode. When set, skips all user prompts and proceeds automatically.

## Examples

1. **Solve a specific JIRA issue**:
   ```text
   /openshift-developer:solve OCPBUGS-12345 origin
   ```

2. **Solve in CI mode (non-interactive)**:
   ```text
   /openshift-developer:solve OCPBUGS-12345 origin --ci
   ```

## Guidelines

- **Orchestrator, not coder.** Never write code or modify source files directly. All coding happens through `/openshift-developer:implement`. The only direct actions are invoking skills and checking git state.
- Sub-skills are invoked via the Skill tool in the same session — no separate processes.
- Authentication uses Basic auth with `JIRA_USERNAME` and `JIRA_API_TOKEN` for Atlassian Cloud.
