# Push Skill

When the user says "push", "commit and push", "send for review", or anything similar, follow this workflow:

## Workflow

### Step 1: Understand the Context

Gather info before doing anything:
- What files were changed? (`git status`, `git diff --stat`)
- Is there a Jira ticket? (check branch name, recent commits, or ask)
- What's the nature of the change?

### Step 2: Determine the Type

Infer from context:
- The Jira ticket type (bug, story, task, etc.)
- The nature of the code changes
- The branch name if one already exists
- What the user said

If it's ambiguous, use the **AskUserQuestion tool** to let the user pick:

- **Bug** — "A fix for broken behavior"
- **Feature** — "New functionality or enhancement"
- **Infra** — "Tooling, refactoring, or infrastructure work"
- **Crash** — "A fix for a crash or fatal error"
- **Design** — "UI/UX changes, layout, or visual updates"

Use lowercase for branch names (`bug/`, `feature/`, `infra/`, `crash/`, `design/`) and capitalized for commit messages (`Bug -`, `Feature -`, `Infra -`, `Crash -`, `Design -`).

### Step 3: Branch

Check the current branch with `git branch --show-current`.

**If on `master`:**
Create a new branch from the cleaned Jira story name:
- Format: `[type]/[descriptive_name_in_snake_case]`
- Keep it concise but readable — aim for 3-6 words
- Use underscores, not hyphens, for word separation in the name part

```
git checkout -b bug/no_validation_error_on_screenshot_fields
```

Examples:
- `bug/no_navigation_bar_on_ob_screen`
- `feature/login_redesign`
- `infra/refactor_login_to_swift`
- `crash/nil_pointer_on_order_creation`

**If already on a branch:** Stay on it. Don't rename it even if it doesn't perfectly match the convention.

### Step 4: Commit

**Stage changes:** Stage all modified/new files relevant to the task. Be mindful — don't stage `.env`, credentials, or files clearly unrelated to the work.

**Check commits ahead of master:**
```
git rev-list --count master..HEAD
```

- **0 commits ahead:** Create a new commit
- **1 commit ahead:** Amend the existing commit (`git commit --amend`)
- **2+ commits ahead:** Use the **AskUserQuestion tool** to let the user decide:
  - **Squash & amend** — "Squash all commits into one and amend with the new changes (recommended for this repo's one-commit-per-PR convention)"
  - **Amend last commit** — "Only amend the most recent commit, keep the rest as-is"
  - **New commit** — "Add a separate commit on top"

**Commit message format** — exactly two lines (or one if no Jira ticket):

```
[Type] - [Clean story name]
[Jira URL]
```

Real examples from the repo:
```
Bug - No validation error on screenshotDisabled text fields in add card
https://gett.atlassian.net/browse/GETT-163552
```
```
Bug - additional space in OB screen
https://gett.atlassian.net/browse/GETT-164648
```
```
Infra - Add daily repo status (Agentic Workflow)
```

Use `printf` piped to `git commit -F -` so the newline is preserved:
```bash
printf 'Bug - No validation error on screenshotDisabled text fields in add card\nhttps://gett.atlassian.net/browse/GETT-163552' | git commit -F -
```

For amends, same format but with `--amend`:
```bash
printf 'Bug - No validation error on screenshotDisabled text fields in add card\nhttps://gett.atlassian.net/browse/GETT-163552' | git commit --amend -F -
```

### Step 5: Push

Push immediately after committing:

- **New branch / first push:** `git push -u origin [branch-name]`
- **Existing tracking branch:** `git push`

If the push is rejected (typically after an amend), use the **AskUserQuestion tool** to let the user choose — don't just ask in plain text. Present options like:

- **Force push** — "Use `--force-with-lease` to overwrite remote (safe for amend workflows)"
- **Cancel** — "Skip the push for now"

Only force push with explicit user confirmation: `git push --force-with-lease`

### Step 6: Pull Request

Check if a PR already exists:
```bash
gh pr list --head [branch-name] --state open
```

**If no PR exists**, use the **AskUserQuestion tool** to let the user choose:

- **Create PR** — "Open a pull request against master (Recommended)"
- **Skip PR** — "Just push, don't create a PR yet"

If they choose to skip, stop here — just report the push was successful. If they choose to create, proceed:
- **Title:** The first line of the commit message (e.g., `Bug - No validation error on screenshotDisabled text fields in add card`)
- **Body:** The Jira URL, or the ticket ID linked as URL `https://gett.atlassian.net/browse/GETT-XXXXX`. If no ticket, body can reference the commit description or be left minimal.
- **Base:** `master`
- **Assignee:** The current user (`@me`)
- **Label:** The type in lowercase — `bug`, `feature`, `infra`, `crash`, `design`, etc. Use whichever label matches the work type. If the label doesn't exist on the repo, skip it rather than erroring.

```bash
gh pr create --title "Bug - No validation error on screenshotDisabled text fields in add card" --body "https://gett.atlassian.net/browse/GETT-163552" --base master --assignee @me --label bug
```

**If a PR already exists**, no action needed — the amend + force push updates it automatically.

Report the PR URL to the user when done.

### Step 7: Update Jira Status & FE Actual Effort

If the Atlassian MCP tools are available and a Jira ticket was provided:

1. **Ask for FE Actual Effort** — use the **AskUserQuestion tool** to ask:

   - **Enter effort** — "How many days of FE effort was this? (e.g. 0.5, 1, 2)"
   - **Skip** — "Leave FE actual effort blank"

2. **Set FE Actual Effort** — if the user provided a value, use `editJiraIssue` to set the field:
   - Field: `customfield_11086` (this is the "FE actual" field)
   - Value: the numeric value the user provided
   ```json
   { "fields": { "customfield_11086": <number> } }
   ```

3. **Transition to In Code Review** — use `getTransitionsForJiraIssue` to find the transition that moves the ticket to **"In Code Review"** (or the closest matching status), then use `transitionJiraIssue` to apply it.

This happens after the PR is created/updated — the code is now out for review, so the Jira status should reflect that. If the transition or field update fails, just mention it to the user and move on. Don't block the workflow over it.

## Summary of Conventions

| Element | Format | Example |
|---------|--------|---------|
| Branch | `type/snake_case_name` | `bug/no_navigation_bar_on_ob_screen` |
| Commit line 1 | `Type - Clean description` | `Bug - No navigation bar on OB screen` |
| Commit line 2 | Jira URL (optional) | `https://gett.atlassian.net/browse/GETT-164648` |
| PR title | Same as commit line 1 | `Bug - No navigation bar on OB screen` |
| PR body | Jira URL | `https://gett.atlassian.net/browse/GETT-164648` |
| Types | `Infra`, `Bug`, `Feature`, `Crash`, `Design` | — |
