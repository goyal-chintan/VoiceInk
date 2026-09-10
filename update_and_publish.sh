#!/bin/bash
set -euo pipefail

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Change directory to repository root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# Developer directory setup
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
elif [ -z "${DEVELOPER_DIR:-}" ]; then
  export DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || echo '')"
fi

echo -e "${BLUE}=== VoiceInk Update & Publish Automation ===${NC}"
echo "Repository: $REPO_ROOT"
echo "Developer Dir: ${DEVELOPER_DIR:-default}"

# Stash management & error trap
STASH_CREATED=false
STASH_NAME=""

cleanup() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    echo -e "\n${RED}[ERROR] Update & Publish failed with exit code $exit_code.${NC}"
    if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
      echo "Aborting rebase in progress..."
      git rebase --abort 2>/dev/null || true
    fi
    if [ -f ".git/MERGE_HEAD" ]; then
      echo "Aborting merge in progress..."
      git merge --abort 2>/dev/null || true
    fi
  fi

  if [ "$STASH_CREATED" = true ]; then
    echo -e "${YELLOW}Restoring stashed local changes (${STASH_NAME})...${NC}"
    if git stash list | grep -q "$STASH_NAME"; then
      git stash pop || echo -e "${YELLOW}[WARNING] Could not automatically pop stash. Your stash '$STASH_NAME' is safely preserved in 'git stash list'.${NC}"
    fi
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# Check prerequisites
for cmd in git xcodebuild ditto; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] Required command '$cmd' is not installed or not in PATH.${NC}"
    exit 1
  fi
done

# Step 1: Stash any uncommitted working tree changes
echo -e "\n${BLUE}=== Step 1: Checking local working tree ===${NC}"
if [ -n "$(git status --porcelain)" ]; then
  STASH_NAME="update_and_publish_auto_stash_$(date +%s)"
  echo "Uncommitted changes detected. Stashing changes with ref '$STASH_NAME'..."
  git stash push -u -m "$STASH_NAME"
  STASH_CREATED=true
else
  echo "Working tree is clean."
fi

# Step 2: Determine current branch and sync remotes
echo -e "\n${BLUE}=== Step 2: Syncing with upstream / origin ===${NC}"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" = "HEAD" ]; then
  echo -e "${RED}[ERROR] Detached HEAD state detected. Please switch to a branch (e.g. main).${NC}"
  exit 1
fi
echo "Current branch: $CURRENT_BRANCH"

SYNC_REMOTE="origin"
if git remote | grep -qx "upstream"; then
  SYNC_REMOTE="upstream"
fi

echo "Fetching latest changes from remote '$SYNC_REMOTE' ($CURRENT_BRANCH)..."
git fetch "$SYNC_REMOTE" "$CURRENT_BRANCH"

REMOTE_REF="$SYNC_REMOTE/$CURRENT_BRANCH"
LOCAL_COMMIT="$(git rev-parse HEAD)"
REMOTE_COMMIT="$(git rev-parse "$REMOTE_REF")"
BASE_COMMIT="$(git merge-base HEAD "$REMOTE_REF")"

if [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ]; then
  echo -e "${GREEN}Local branch is already up to date with $REMOTE_REF.${NC}"
elif [ "$LOCAL_COMMIT" = "$BASE_COMMIT" ]; then
  echo "Fast-forwarding to $REMOTE_REF..."
  git merge --ff-only "$REMOTE_REF"
elif [ "$REMOTE_COMMIT" = "$BASE_COMMIT" ]; then
  echo "Local branch is ahead of $REMOTE_REF (keeping local commits intact)."
else
  echo "Local branch has local commits and upstream has new commits."
  echo "Rebasing local commits onto $REMOTE_REF to preserve all local enhancements..."
  if ! git rebase "$REMOTE_REF"; then
    echo -e "${RED}[ERROR] Rebase conflict detected while syncing with $REMOTE_REF.${NC}"
    echo "Aborting rebase..."
    git rebase --abort 2>/dev/null || true
    echo -e "${YELLOW}Please resolve the conflict manually, or review changes.${NC}"
    exit 1
  fi
  echo -e "${GREEN}Rebase successful. Local enhancements preserved on top of upstream.${NC}"
fi

# Step 3: Sync fork (origin) if upstream was used
if git remote | grep -qx "origin" && [ "$SYNC_REMOTE" = "upstream" ]; then
  echo "Syncing updated $CURRENT_BRANCH to your fork ('origin')..."
  git push origin "$CURRENT_BRANCH" 2>/dev/null || echo -e "${YELLOW}Notice: Could not automatically push to origin. Continuing with local build.${NC}"
fi

# Step 4: Restore stashed changes before building if any were stashed
if [ "$STASH_CREATED" = true ]; then
  echo -e "\n${BLUE}=== Step 4: Restoring uncommitted local changes ===${NC}"
  if git stash list | grep -q "$STASH_NAME"; then
    git stash pop
    STASH_CREATED=false
  fi
fi

# Step 5: Build VoiceInk locally
echo -e "\n${BLUE}=== Step 5: Building VoiceInk locally ===${NC}"
rm -rf "$HOME/Downloads/VoiceInk.app"
make local

BUILT_APP="$HOME/Downloads/VoiceInk.app"
if [ ! -d "$BUILT_APP" ] || [ ! -f "$BUILT_APP/Contents/MacOS/VoiceInk" ]; then
  echo -e "${RED}[ERROR] Build failed or output app not found at $BUILT_APP.${NC}"
  exit 1
fi
echo -e "${GREEN}Build verified successfully at $BUILT_APP.${NC}"

# Step 6: Close running instance safely
echo -e "\n${BLUE}=== Step 6: Managing running instance ===${NC}"
WAS_RUNNING=false
if pgrep -x "VoiceInk" > /dev/null; then
  WAS_RUNNING=true
  echo "VoiceInk is currently running. Requesting graceful shutdown..."
  osascript -e 'tell application "VoiceInk" to quit' 2>/dev/null || killall -TERM "VoiceInk" 2>/dev/null || true

  WAIT_COUNT=0
  while pgrep -x "VoiceInk" > /dev/null && [ "$WAIT_COUNT" -lt 10 ]; do
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
  done

  if pgrep -x "VoiceInk" > /dev/null; then
    echo -e "${YELLOW}VoiceInk did not terminate within 10 seconds. Force stopping...${NC}"
    killall -KILL "VoiceInk" 2>/dev/null || true
    sleep 1
  fi
fi

if pgrep -x "VoiceInk" > /dev/null; then
  echo -e "${RED}[ERROR] Failed to stop running VoiceInk process. Aborting publish.${NC}"
  exit 1
fi
echo "VoiceInk process status: stopped."

# Step 7: Publish to /Applications
echo -e "\n${BLUE}=== Step 7: Publishing to /Applications ===${NC}"
DEST_APP="/Applications/VoiceInk.app"
TEMP_BACKUP=""

if [ -d "$DEST_APP" ]; then
  TEMP_BACKUP="/Applications/VoiceInk.app.backup.$$"
  mv "$DEST_APP" "$TEMP_BACKUP"
fi

echo "Copying built app to $DEST_APP..."
if ditto "$BUILT_APP" "$DEST_APP"; then
  echo "Stripping quarantine attributes..."
  xattr -cr "$DEST_APP"

  # Ensure stable code signing identity with entitlements is applied
  SIGNING_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '$2 ~ /^Apple Development: / { print $2; exit }')"
  if [ -z "$SIGNING_ID" ]; then
    SIGNING_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '$2 ~ /(Mac Developer|.*Development|.*Dev.*)/ { print $2; exit }')"
  fi
  if [ -n "$SIGNING_ID" ]; then
    echo "Applying stable code signature to $DEST_APP: $SIGNING_ID..."
    codesign --force --deep --sign "$SIGNING_ID" \
      --entitlements "$REPO_ROOT/VoiceInk/VoiceInk.local.entitlements" \
      --options runtime \
      "$DEST_APP"
  fi

  if [ -n "$TEMP_BACKUP" ] && [ -d "$TEMP_BACKUP" ]; then
    rm -rf "$TEMP_BACKUP"
  fi
  echo -e "${GREEN}Installed successfully to $DEST_APP.${NC}"
else
  echo -e "${RED}[ERROR] Failed to copy to $DEST_APP. Restoring previous version...${NC}"
  if [ -n "$TEMP_BACKUP" ] && [ -d "$TEMP_BACKUP" ]; then
    mv "$TEMP_BACKUP" "$DEST_APP"
  fi
  exit 1
fi

# Step 8: Relaunch if previously running
echo -e "\n${BLUE}=== Step 8: Finalizing ===${NC}"
if [ "$WAS_RUNNING" = true ]; then
  echo "Relaunching VoiceInk..."
  open "$DEST_APP"
  echo -e "${GREEN}VoiceInk relaunched successfully!${NC}"
else
  echo -e "${GREEN}VoiceInk is updated! You can launch it from $DEST_APP.${NC}"
fi

echo -e "\n${GREEN}=== VoiceInk Update & Publish Completed Successfully! ===${NC}"
