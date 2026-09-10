#!/bin/bash
set -e

# Change directory to the repository root
cd "$(dirname "$0")"

# Use full Xcode instead of command line tools for xcodebuild
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

echo "=== Stashing any local changes ==="
STASH_CREATED=false
if ! git diff-index --quiet HEAD --; then
  echo "Local changes detected. Stashing..."
  git stash
  STASH_CREATED=true
fi

echo "=== Syncing with upstream/origin ==="
if git remote | grep -q 'upstream'; then
  echo "Syncing from remote 'upstream'..."
  git pull upstream main
else
  echo "Syncing from remote 'origin'..."
  git pull origin main
fi

if [ "$STASH_CREATED" = true ]; then
  echo "Restoring stashed local changes..."
  git stash pop
fi

echo "=== Building VoiceInk locally ==="
make local

echo "=== Publishing to Applications ==="
if pgrep -x "VoiceInk" > /dev/null; then
  echo "VoiceInk is running. Closing it..."
  killall "VoiceInk" || true
  sleep 2
fi

echo "Copying built app to /Applications..."
rm -rf "/Applications/VoiceInk.app"
ditto "$HOME/Downloads/VoiceInk.app" "/Applications/VoiceInk.app"
xattr -cr "/Applications/VoiceInk.app"

echo "=== VoiceInk updated successfully! ==="
echo "You can launch it from /Applications/VoiceInk.app"
