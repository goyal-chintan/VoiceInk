#!/bin/bash
set -euo pipefail

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global state for traps & cleanup
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_APP="/Applications/VoiceInk.app"
STASH_CREATED=false
STASH_NAME=""
TEMP_BACKUP=""

cleanup() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    echo -e "\n${RED}[ERROR] Update & Publish failed with exit code $exit_code.${NC}"
    if [ -d "$REPO_ROOT/.git/rebase-merge" ] || [ -d "$REPO_ROOT/.git/rebase-apply" ]; then
      echo "Aborting rebase in progress..."
      git -C "$REPO_ROOT" rebase --abort 2>/dev/null || true
    fi
    if [ -f "$REPO_ROOT/.git/MERGE_HEAD" ]; then
      echo "Aborting merge in progress..."
      git -C "$REPO_ROOT" merge --abort 2>/dev/null || true
    fi
    if [ -n "${TEMP_BACKUP:-}" ] && [ -d "$TEMP_BACKUP" ]; then
      echo -e "${YELLOW}Restoring previous application from backup ($TEMP_BACKUP)...${NC}"
      rm -rf "$DEST_APP" 2>/dev/null || true
      mv "$TEMP_BACKUP" "$DEST_APP" 2>/dev/null || true
      TEMP_BACKUP=""
    fi
  fi

  if [ "$STASH_CREATED" = true ] && [ -n "$STASH_NAME" ]; then
    echo -e "${YELLOW}Restoring stashed local changes (${STASH_NAME})...${NC}"
    local stash_ref
    stash_ref="$(git -C "$REPO_ROOT" stash list 2>/dev/null | grep "$STASH_NAME" | head -n 1 | awk -F: '{print $1}' || true)"
    if [ -n "$stash_ref" ]; then
      git -C "$REPO_ROOT" stash pop "$stash_ref" 2>/dev/null || echo -e "${YELLOW}[WARNING] Could not automatically pop stash. Your stash '$STASH_NAME' is safely preserved in 'git stash list'.${NC}"
    fi
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# Wrapped in main() to guarantee bash loads the full script into memory before execution,
# preventing file pointer corruption if git stash/rebase touches this script on disk.
main() {
  cd "$REPO_ROOT"

  local skip_sync=false
  local skip_build=false
  local no_relaunch=false

  usage() {
    cat << 'EOF'
Usage: ./update_and_publish.sh [OPTIONS]

VoiceInk Update, Build & Publish Automation

Options:
  --skip-sync, --no-sync   Skip git fetch, rebase, and remote sync
  --skip-build, --no-build Skip build step (publish existing ~/Downloads/VoiceInk.app)
  --no-relaunch            Do not relaunch VoiceInk after installation
  -h, --help               Show this help message

Environment Variables:
  LOCAL_CODESIGN_IDENTITY  Override code signing identity (e.g. "Apple Development: ...")
  DEVELOPER_DIR            Override Xcode developer directory path
EOF
  }

  while [ $# -gt 0 ]; do
    case "$1" in
      --skip-sync|--no-sync)
        skip_sync=true
        shift
        ;;
      --skip-build|--no-build)
        skip_build=true
        shift
        ;;
      --no-relaunch)
        no_relaunch=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo -e "${RED}[ERROR] Unknown option: $1${NC}"
        usage
        exit 1
        ;;
    esac
  done

  # Developer directory setup (preserve DEVELOPER_DIR if already set)
  if [ -z "${DEVELOPER_DIR:-}" ]; then
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
      export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    else
      export DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || echo '')"
    fi
  fi

  # Code signing identity resolution (matches Makefile priority)
  local signing_id="${LOCAL_CODESIGN_IDENTITY:-}"
  if [ -z "$signing_id" ]; then
    signing_id="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '$2 ~ /^Apple Development: / { print $2; exit }')"
    if [ -z "$signing_id" ]; then
      signing_id="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '$2 ~ /(Mac Developer|.*Development|.*Dev.*)/ { print $2; exit }')"
    fi
  fi
  if [ -n "$signing_id" ]; then
    export LOCAL_CODESIGN_IDENTITY="$signing_id"
  fi

  echo -e "${BLUE}=== VoiceInk Update & Publish Automation ===${NC}"
  echo "Repository: $REPO_ROOT"
  echo "Developer Dir: ${DEVELOPER_DIR:-default}"
  echo "Signing Identity: ${signing_id:-ad-hoc fallback}"

  # Check prerequisites
  local required_cmds=(git ditto)
  if [ "$skip_build" = false ]; then
    required_cmds+=(xcodebuild make)
  fi

  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo -e "${RED}[ERROR] Required command '$cmd' is not installed or not in PATH.${NC}"
      exit 1
    fi
  done

  # Verify Metal toolchain is available (required by MLX and Swift packages for Metal shaders)
  if [ "$skip_build" = false ]; then
    if ! xcrun metal --version >/dev/null 2>&1; then
      echo -e "${YELLOW}Metal toolchain missing. Downloading required Xcode MetalToolchain component...${NC}"
      if xcodebuild -downloadComponent MetalToolchain; then
        echo -e "${GREEN}Metal toolchain installed successfully.${NC}"
      else
        echo -e "${RED}[ERROR] Failed to download MetalToolchain. Metal shaders cannot be compiled.${NC}"
        exit 1
      fi
    fi
  fi

  # Check write permissions for destination early
  if [ -d "$DEST_APP" ] && [ ! -w "$DEST_APP" ]; then
    echo -e "${RED}[ERROR] Destination $DEST_APP is not writable by current user ($USER).${NC}"
    exit 1
  elif [ ! -d "$DEST_APP" ] && [ ! -w "/Applications" ]; then
    echo -e "${RED}[ERROR] /Applications is not writable by current user ($USER).${NC}"
    exit 1
  fi

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
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$current_branch" = "HEAD" ]; then
    echo -e "${RED}[ERROR] Detached HEAD state detected. Please switch to a branch (e.g. main).${NC}"
    exit 1
  fi

  local sync_remote="origin"
  if [ "$skip_sync" = true ]; then
    echo -e "\n${BLUE}=== Step 2: Skipping remote sync (--skip-sync) ===${NC}"
  else
    echo -e "\n${BLUE}=== Step 2: Syncing with upstream / origin ===${NC}"
    echo "Current branch: $current_branch"

    if git remote | grep -qx "upstream"; then
      sync_remote="upstream"
    fi

    # Determine target branch on remote (fallback to remote default branch if current branch doesn't exist on remote)
    local target_remote_branch="$current_branch"
    if ! git ls-remote --exit-code --heads "$sync_remote" "$current_branch" >/dev/null 2>&1; then
      local upstream_default_branch
      upstream_default_branch="$(git symbolic-ref --short refs/remotes/"$sync_remote"/HEAD 2>/dev/null | sed "s@^$sync_remote/@@" || echo 'main')"
      echo -e "${YELLOW}Branch '$current_branch' not found on remote '$sync_remote'. Syncing against '$sync_remote/$upstream_default_branch'...${NC}"
      target_remote_branch="$upstream_default_branch"
    fi

    echo "Fetching latest changes from remote '$sync_remote' ($target_remote_branch)..."
    if ! git fetch "$sync_remote" "$target_remote_branch"; then
      echo -e "${YELLOW}[WARNING] Could not fetch from remote '$sync_remote'. Network may be offline.${NC}"
      echo -e "${YELLOW}Continuing with existing local branch without remote update...${NC}"
    else
      local remote_ref="$sync_remote/$target_remote_branch"
      local local_commit
      local remote_commit
      local base_commit
      local_commit="$(git rev-parse HEAD)"
      remote_commit="$(git rev-parse "$remote_ref")"
      base_commit="$(git merge-base HEAD "$remote_ref")"

      if [ "$local_commit" = "$remote_commit" ]; then
        echo -e "${GREEN}Local branch is already up to date with $remote_ref.${NC}"
      elif [ "$local_commit" = "$base_commit" ]; then
        echo "Fast-forwarding to $remote_ref..."
        git merge --ff-only "$remote_ref"
      elif [ "$remote_commit" = "$base_commit" ]; then
        echo "Local branch is ahead of $remote_ref (keeping local commits intact)."
      else
        echo "Local branch has local commits and upstream has new commits."
        echo "Rebasing local commits onto $remote_ref to preserve all local enhancements..."
        if ! git rebase "$remote_ref"; then
          echo -e "${RED}[ERROR] Rebase conflict detected while syncing with $remote_ref.${NC}"
          echo "Aborting rebase..."
          git rebase --abort 2>/dev/null || true
          echo -e "${YELLOW}Please resolve the conflict manually, or review changes.${NC}"
          exit 1
        fi
        echo -e "${GREEN}Rebase successful. Local enhancements preserved on top of upstream.${NC}"
      fi
    fi
  fi

  # Step 3: Sync fork (origin) if upstream was used
  if [ "$skip_sync" = false ] && git remote | grep -qx "origin" && [ "$sync_remote" = "upstream" ]; then
    echo -e "\n${BLUE}=== Step 3: Syncing fork ('origin') ===${NC}"
    echo "Syncing updated $current_branch to your fork ('origin')..."
    git fetch origin "$current_branch" 2>/dev/null || true

    if git push origin "$current_branch" 2>/dev/null; then
      echo -e "${GREEN}Fork ('origin') synchronized successfully.${NC}"
    elif PUSH_OUT=$(git push --force-with-lease origin "$current_branch" 2>&1); then
      echo -e "${GREEN}Fork ('origin') synchronized successfully (rebased history updated via force-with-lease).${NC}"
    else
      echo -e "${YELLOW}[WARNING] Could not automatically push to origin ($current_branch).${NC}"
      echo -e "${YELLOW}Git output: ${PUSH_OUT}${NC}"
      echo -e "${YELLOW}Continuing with local build...${NC}"
    fi
  fi

  # Step 4: Restore stashed changes before building if any were stashed
  if [ "$STASH_CREATED" = true ] && [ -n "$STASH_NAME" ]; then
    echo -e "\n${BLUE}=== Step 4: Restoring uncommitted local changes ===${NC}"
    local stash_ref
    stash_ref="$(git stash list 2>/dev/null | grep "$STASH_NAME" | head -n 1 | awk -F: '{print $1}' || true)"
    if [ -n "$stash_ref" ]; then
      echo "Restoring stashed changes ($stash_ref: $STASH_NAME)..."
      if git stash pop "$stash_ref"; then
        STASH_CREATED=false
        echo -e "${GREEN}Local changes restored successfully.${NC}"
      else
        echo -e "${RED}[ERROR] Conflict detected when restoring stashed changes ($STASH_NAME).${NC}"
        echo -e "${YELLOW}Your changes remain safely in 'git stash list'. Please resolve conflicts.${NC}"
        STASH_CREATED=false
        exit 1
      fi
    fi
  fi

  # Step 5: Build VoiceInk locally
  echo -e "\n${BLUE}=== Step 5: Building VoiceInk locally ===${NC}"
  local built_app="$HOME/Downloads/VoiceInk.app"

  if [ "$skip_build" = true ]; then
    echo "Skipping build step (--skip-build). Using existing app at $built_app..."
  else
    rm -rf "$built_app"
    if [ -n "$signing_id" ]; then
      LOCAL_CODESIGN_IDENTITY="$signing_id" make local
    else
      make local
    fi
  fi

  if [ ! -d "$built_app" ] || [ ! -f "$built_app/Contents/MacOS/VoiceInk" ]; then
    echo -e "${RED}[ERROR] Built app not found or incomplete at $built_app.${NC}"
    exit 1
  fi
  echo -e "${GREEN}Build verified successfully at $built_app.${NC}"

  # Step 6: Close running instance safely
  echo -e "\n${BLUE}=== Step 6: Managing running instance ===${NC}"
  local was_running=false
  if pgrep -x "VoiceInk" >/dev/null 2>&1; then
    was_running=true
    echo "VoiceInk is currently running. Requesting graceful shutdown..."
    osascript -e 'tell application "VoiceInk" to quit' 2>/dev/null || killall -TERM "VoiceInk" 2>/dev/null || true

    local wait_count=0
    while pgrep -x "VoiceInk" >/dev/null 2>&1 && [ "$wait_count" -lt 10 ]; do
      sleep 1
      wait_count=$((wait_count + 1))
    done

    if pgrep -x "VoiceInk" >/dev/null 2>&1; then
      echo -e "${YELLOW}VoiceInk did not terminate within 10 seconds. Force stopping...${NC}"
      killall -KILL "VoiceInk" 2>/dev/null || true
      sleep 1
    fi
  fi

  if pgrep -x "VoiceInk" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] Failed to stop running VoiceInk process. Aborting publish.${NC}"
    exit 1
  fi
  echo "VoiceInk process status: stopped."

  # Step 7: Publish to /Applications
  echo -e "\n${BLUE}=== Step 7: Publishing to /Applications ===${NC}"
  TEMP_BACKUP=""

  if [ -d "$DEST_APP" ]; then
    TEMP_BACKUP="/Applications/VoiceInk.app.backup.$$"
    echo "Backing up current installation to $TEMP_BACKUP..."
    mv "$DEST_APP" "$TEMP_BACKUP"
  fi

  echo "Copying built app to $DEST_APP..."
  if ditto "$built_app" "$DEST_APP"; then
    echo "Stripping quarantine and extended attributes..."
    xattr -cr "$DEST_APP"

    # Ensure stable code signing identity with entitlements is applied
    local entitlements_file="$REPO_ROOT/VoiceInk/VoiceInk.local.entitlements"
    if [ -n "$signing_id" ] && [ "$signing_id" != "-" ]; then
      echo "Applying stable code signature to $DEST_APP ($signing_id)..."
      codesign --force --deep --sign "$signing_id" \
        --entitlements "$entitlements_file" \
        --options runtime \
        "$DEST_APP"
    else
      echo "Ensuring code signature of $DEST_APP..."
      if ! codesign -v "$DEST_APP" 2>/dev/null; then
        echo "Applying ad-hoc code signature to $DEST_APP..."
        codesign --force --deep --sign - \
          --entitlements "$entitlements_file" \
          --options runtime \
          "$DEST_APP"
      fi
    fi

    echo "Verifying code signature validity..."
    if ! codesign --verify --deep --strict "$DEST_APP" >/dev/null 2>&1; then
      echo -e "${RED}[ERROR] Code signing verification failed for $DEST_APP.${NC}"
      if [ -n "$TEMP_BACKUP" ] && [ -d "$TEMP_BACKUP" ]; then
        echo "Restoring previous version from backup..."
        rm -rf "$DEST_APP" 2>/dev/null || true
        mv "$TEMP_BACKUP" "$DEST_APP"
        TEMP_BACKUP=""
      fi
      exit 1
    fi

    if [ -n "$TEMP_BACKUP" ] && [ -d "$TEMP_BACKUP" ]; then
      echo "Removing temporary backup..."
      rm -rf "$TEMP_BACKUP"
      TEMP_BACKUP=""
    fi
    echo -e "${GREEN}Installed and verified successfully at $DEST_APP.${NC}"
  else
    echo -e "${RED}[ERROR] Failed to copy to $DEST_APP. Restoring previous version...${NC}"
    if [ -n "$TEMP_BACKUP" ] && [ -d "$TEMP_BACKUP" ]; then
      mv "$TEMP_BACKUP" "$DEST_APP"
      TEMP_BACKUP=""
    fi
    exit 1
  fi

  # Step 8: Relaunch if previously running
  echo -e "\n${BLUE}=== Step 8: Finalizing ===${NC}"
  if [ "$no_relaunch" = false ] && [ "$was_running" = true ]; then
    echo "Relaunching VoiceInk..."
    open "$DEST_APP"
    echo -e "${GREEN}VoiceInk relaunched successfully!${NC}"
  else
    echo -e "${GREEN}VoiceInk is updated! You can launch it from $DEST_APP.${NC}"
  fi

  echo -e "\n${GREEN}=== VoiceInk Update & Publish Completed Successfully! ===${NC}"
}

main "$@"
