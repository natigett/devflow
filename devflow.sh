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

# ── 1. Push ──
echo "⏳ Pushing to remote..."
git push -u origin "$BRANCH"
echo "✅ Pushed"

# ── 2. Create PR ──
echo "⏳ Creating Pull Request..."
PR_RESPONSE=$(curl -s -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO_SLUG/pulls" \
  -d "$(python3 -c "
import json
print(json.dumps({
    'title': '$COMMIT_MSG [$JIRA_KEY]',
    'head': '$BRANCH',
    'base': '$TARGET_BRANCH',
    'body': 'Jira: $JIRA_URL'
}))")")

PR_URL=$(echo "$PR_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('html_url',''))")

if [[ -z "$PR_URL" ]]; then
  echo "❌ Failed to create PR"
  echo "$PR_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','Unknown error'))"
  exit 1
fi
echo "✅ PR created: $PR_URL"

# ── 3. Slack notification ──
echo "⏳ Sending Slack message to $REVIEWER..."

# Look up Slack user ID by display name
SLACK_USERS=$(curl -s -H "Authorization: Bearer $SLACK_TOKEN" "https://slack.com/api/users.list?limit=500")
SLACK_USER_ID=$(echo "$SLACK_USERS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
name = '$REVIEWER'
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

  curl -s -X POST \
    -H "Authorization: Bearer $SLACK_TOKEN" \
    -H "Content-Type: application/json" \
    "https://slack.com/api/chat.postMessage" \
    -d "$(python3 -c "
import json
print(json.dumps({
    'channel': '$DM_CHANNEL',
    'text': '👋 Hey! Could you please review my PR?\n*$COMMIT_MSG* [$JIRA_KEY]\n🔗 $PR_URL\n📋 $JIRA_URL'
}))")" > /dev/null

  echo "✅ Slack message sent"
fi

# ── 4. Update Jira status ──
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
