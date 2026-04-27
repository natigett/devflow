#!/bin/bash

# DevFlow — Automate: push → PR → Slack → Jira
# Install: chmod +x ~/.devflow/devflow.sh && ln -sf ~/.devflow/devflow.sh /usr/local/bin/devflow

set -euo pipefail

CONFIG_FILE="$HOME/.devflow/config.json"

# ── Parse config ──
read_config() { python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['$1'])"; }

GITHUB_TOKEN=$(read_config github_token)
SLACK_TOKEN=$(read_config slack_bot_token)
JIRA_BASE_URL=$(read_config jira_base_url)
JIRA_EMAIL=$(read_config jira_email)
JIRA_API_TOKEN=$(read_config jira_api_token)
JIRA_TRANSITION_NAME=$(read_config jira_transition_name)
DEFAULT_TARGET=$(read_config default_target_branch)

# ── Parse arguments ──
COMMIT_MSG=""
JIRA_URL=""
REVIEWER=""
TARGET_BRANCH="$DEFAULT_TARGET"

while [[ $# -gt 0 ]]; do
  case $1 in
    -message:*) COMMIT_MSG="${1#-message:}" ;;
    -jira:*) JIRA_URL="${1#-jira:}" ;;
    -reviewer:*) REVIEWER="${1#-reviewer:}" ;;
    -target:*) TARGET_BRANCH="${1#-target:}" ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

[[ -z "$COMMIT_MSG" ]] && echo "❌ -message: is required" && exit 1
[[ -z "$JIRA_URL" ]] && echo "❌ -jira: is required" && exit 1
[[ -z "$REVIEWER" ]] && echo "❌ -reviewer: is required" && exit 1

# Extract Jira issue key from URL (e.g. https://domain.atlassian.net/browse/PROJ-123)
JIRA_KEY=$(echo "$JIRA_URL" | grep -oE '[A-Z]+-[0-9]+' | tail -1)
FULL_COMMIT_MSG="$COMMIT_MSG [$JIRA_KEY] $JIRA_URL"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Detect GitHub repo (owner/repo) from git remote
REPO_SLUG=$(git remote get-url origin | sed -E 's#.*github\.com[:/](.+)\.git$#\1#' | sed -E 's#.*github\.com[:/](.+)$#\1#')

echo "══════════════════════════════════════"
echo "  DevFlow Automation"
echo "══════════════════════════════════════"
echo "  Branch:  $BRANCH → $TARGET_BRANCH"
echo "  Repo:    $REPO_SLUG"
echo "  Jira:    $JIRA_KEY"
echo "  Reviewer: $REVIEWER"
echo "══════════════════════════════════════"

# ── 1. Commit & Push ──
STAGED=$(git diff --cached --name-only)
UNSTAGED=$(git diff --name-only)
if [[ -n "$STAGED" || -n "$UNSTAGED" ]]; then
  echo "⏳ Committing changes..."
  git add -A
  git commit -m "$FULL_COMMIT_MSG"
  echo "✅ Committed"
else
  echo "⏭️  No uncommitted changes, skipping commit"
fi

echo "⏳ Pushing to remote..."
git push -u origin "$BRANCH"
echo "✅ Pushed"

# ── 2. Create PR ──
echo "⏳ Creating Pull Request..."
PR_BODY=$(PR_TITLE="$COMMIT_MSG [$JIRA_KEY]" PR_HEAD="$BRANCH" PR_BASE="$TARGET_BRANCH" PR_JIRA="$JIRA_URL" python3 -c "
import json, os
print(json.dumps({
    'title': os.environ['PR_TITLE'],
    'head': os.environ['PR_HEAD'],
    'base': os.environ['PR_BASE'],
    'body': 'Jira: ' + os.environ['PR_JIRA']
}))")

PR_RESPONSE=$(curl -s -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO_SLUG/pulls" \
  -d "$PR_BODY")

PR_URL=$(echo "$PR_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('html_url',''))")

if [[ -z "$PR_URL" ]]; then
  echo "❌ Failed to create PR"
  echo "$PR_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('Message:', data.get('message','Unknown error'))
for e in data.get('errors', []):
    print('  -', e.get('message', e))
"
  exit 1
fi
echo "✅ PR created: $PR_URL"

# ── 3. Generate AI changes summary ──
echo "⏳ Generating changes summary..."
DIFF_CONTENT=$(git diff "$TARGET_BRANCH"..."$BRANCH" 2>/dev/null | head -c 12000 || echo "")

if [[ -n "$GITHUB_TOKEN" && "$GITHUB_TOKEN" != "PASTE_YOUR_GITHUB_TOKEN" && -n "$DIFF_CONTENT" ]]; then
  CHANGES_SUMMARY=$(DIFF_INPUT="$DIFF_CONTENT" GH_TOKEN="$GITHUB_TOKEN" python3 << 'PYEOF'
import json, urllib.request, sys, os

diff = os.environ.get("DIFF_INPUT", "")
token = os.environ.get("GH_TOKEN", "")

body = json.dumps({
    "model": "gpt-4o-mini",
    "messages": [
        {"role": "system", "content": "You summarize code diffs for PR review messages on Slack. Write 1-3 short bullet points describing WHAT changed and WHY it matters. Be concise, developer-friendly. No markdown, use plain text with • bullets. Max 300 chars total."},
        {"role": "user", "content": f"Summarize this diff:\n{diff}"}
    ],
    "max_tokens": 150,
    "temperature": 0.3
}).encode()

req = urllib.request.Request(
    "https://models.inference.ai.azure.com/chat/completions",
    data=body,
    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
)
try:
    resp = urllib.request.urlopen(req, timeout=15)
    result = json.loads(resp.read())
    print(result["choices"][0]["message"]["content"].strip())
except Exception as e:
    print(f"Could not generate AI summary: {e}", file=sys.stderr)
    print("No summary available")
PYEOF
  )
else
  # Fallback: basic file list
  DIFF_STAT=$(git diff "$TARGET_BRANCH"..."$BRANCH" --stat 2>/dev/null || echo "")
  CHANGES_SUMMARY=$(python3 -c "
stat = '''$DIFF_STAT'''
files = [l.strip().split('|')[0].strip() for l in stat.strip().split('\n') if '|' in l]
print(', '.join(files[:10]) if files else 'No summary available')
" 2>/dev/null || echo "No summary available")
fi
echo "✅ Summary: $CHANGES_SUMMARY"

# ── 4. Slack notification ──
echo "⏳ Sending Slack message to $REVIEWER..."

# Look up Slack user ID by display name
SLACK_USERS=$(curl -s -H "Authorization: Bearer $SLACK_TOKEN" "https://slack.com/api/users.list?limit=500")
SLACK_USER_ID=$(echo "$SLACK_USERS" | REVIEWER_NAME="$REVIEWER" python3 -c "
import sys, json, os
data = json.load(sys.stdin)
name = os.environ['REVIEWER_NAME']
for u in data.get('members', []):
    if u.get('name') == name or u.get('profile',{}).get('display_name') == name or u.get('real_name') == name:
        print(u['id']); break
" 2>/dev/null || true)

if [[ -z "$SLACK_USER_ID" ]]; then
  echo "⚠️  Could not find Slack user '$REVIEWER'. Skipping Slack."
else
  # Open DM channel
  DM_CHANNEL=$(curl -s -X POST \
    -H "Authorization: Bearer $SLACK_TOKEN" \
    -H "Content-Type: application/json" \
    "https://slack.com/api/conversations.open" \
    -d "{\"users\":\"$SLACK_USER_ID\"}" | python3 -c "import sys,json; print(json.load(sys.stdin)['channel']['id'])")

  SLACK_MSG=$(SLACK_CH="$DM_CHANNEL" SLACK_REVIEWER="$REVIEWER" SLACK_PR="$PR_URL" SLACK_JIRA="$JIRA_URL" SLACK_SUMMARY="$CHANGES_SUMMARY" python3 -c "
import json, os
msg = f'Hey @{os.environ[\"SLACK_REVIEWER\"]} :)\nI have new PR to your review: {os.environ[\"SLACK_PR\"]}\nThis is about {os.environ[\"SLACK_JIRA\"]}\n\nDetails: {os.environ[\"SLACK_SUMMARY\"]}'
print(json.dumps({'channel': os.environ['SLACK_CH'], 'text': msg}))
")

  curl -s -X POST \
    -H "Authorization: Bearer $SLACK_TOKEN" \
    -H "Content-Type: application/json" \
    "https://slack.com/api/chat.postMessage" \
    -d "$SLACK_MSG" > /dev/null

  echo "✅ Slack message sent"
fi

# ── 5. Update Jira status ──
echo "⏳ Updating Jira $JIRA_KEY → $JIRA_TRANSITION_NAME..."

JIRA_AUTH=$(echo -n "$JIRA_EMAIL:$JIRA_API_TOKEN" | base64)

# Get available transitions
TRANSITIONS=$(curl -s \
  -H "Authorization: Basic $JIRA_AUTH" \
  -H "Content-Type: application/json" \
  "$JIRA_BASE_URL/rest/api/3/issue/$JIRA_KEY/transitions")

TRANSITION_ID=$(echo "$TRANSITIONS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
target = '$JIRA_TRANSITION_NAME'.lower()
for t in data.get('transitions', []):
    if t['name'].lower() == target:
        print(t['id']); break
" 2>/dev/null || true)

if [[ -z "$TRANSITION_ID" ]]; then
  echo "⚠️  Could not find transition '$JIRA_TRANSITION_NAME' for $JIRA_KEY. Skipping."
else
  curl -s -X POST \
    -H "Authorization: Basic $JIRA_AUTH" \
    -H "Content-Type: application/json" \
    "$JIRA_BASE_URL/rest/api/3/issue/$JIRA_KEY/transitions" \
    -d "{\"transition\":{\"id\":\"$TRANSITION_ID\"}}" > /dev/null
  echo "✅ Jira updated"
fi

echo ""
echo "🎉 All done!"
echo "   PR: $PR_URL"
