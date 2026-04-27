# DevFlow — Post-Coding Automation

## Overview
Automates the "last mile" after coding: **Push → PR → Slack → Jira** — works across all your projects.

## Architecture

```
~/.devflow/
├── config.json      ← Global tokens & defaults (one-time setup)
└── devflow.sh       ← The automation script (symlinked to PATH)
```

**Global by design** — config lives in `~/.devflow/`, works with any Git repo.

---

## Setup (One-Time)

### 1. Fill in `~/.devflow/config.json`

| Field | How to get it |
|-------|--------------|
| `github_token` | GitHub → Settings → Developer settings → Personal access tokens → Generate (scopes: `repo`) |
| `slack_bot_token` | Create a Slack App → OAuth → Bot Token (scopes: `users:read`, `chat:write`, `im:write`) |
| `jira_base_url` | e.g. `https://yourcompany.atlassian.net` |
| `jira_email` | Your Atlassian account email |
| `jira_api_token` | Atlassian → Account → Security → API tokens → Create |
| `jira_transition_name` | The exact name of the "In Code Review" status in your Jira workflow |

### 2. Make executable
```bash
chmod +x ~/.devflow/devflow.sh
# Option A: symlink
sudo ln -sf ~/.devflow/devflow.sh /usr/local/bin/devflow
# Option B: alias in ~/.zshrc
echo 'alias devflow="~/.devflow/devflow.sh"' >> ~/.zshrc && source ~/.zshrc
```

---

## Usage

### Command format (prompt to Copilot):
```
Commit -message:"<message>" -jira:"<jira-url>" -reviewer:"<slack-display-name>"
```

### Example:
```
Commit -message:"Fix PubNub reconnection logic" -jira:"https://mycompany.atlassian.net/browse/DBX-1234" -reviewer:"john.doe"
```

### What happens:
1. ✅ Pushes current branch to origin
2. ✅ Creates a GitHub PR (branch → master) with Jira link in title & body
3. ✅ Sends a Slack DM to the reviewer with the PR link
4. ✅ Transitions the Jira issue to "In Code Review"

### Optional flags:
- `-target:develop` — PR target branch (default: `master`)

---

## Multi-Project Support

No per-project config needed. The script reads the Git remote URL to detect the GitHub repo automatically. Just run it from any Git repo.
