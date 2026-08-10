#!/bin/bash
# clone-repo.sh — helper to clone a repository into the persistent workspace.
# Usage: clone-repo.sh <git-url> [<subdir>]
set -e

REPO_URL="${1:?Usage: clone-repo.sh <git-url> [<subdir>]}"
DEST="${2:-/config/workspace/$(basename "$REPO_URL" .git)}"

mkdir -p "$(dirname "$DEST")"

if [ -d "$DEST/.git" ]; then
	echo "Workspace '$DEST' already exists — pulling latest." >&2
	git -C "$DEST" pull --ff-only || true
else
	git clone "$REPO_URL" "$DEST"
fi

echo "$DEST"
