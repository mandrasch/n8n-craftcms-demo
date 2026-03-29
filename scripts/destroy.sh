#!/bin/bash
set -euo pipefail

REPO_NAME="$1"
PR_NUMBER="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env"

# Build unique preview ID from repo name + PR number
REPO_SLUG=$(echo "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
PREVIEW_ID="${REPO_SLUG}-pr-${PR_NUMBER}"
DB_NAME="craft_${PREVIEW_ID//-/_}"
PREVIEW_DIR="$HOME/preview-system/previews/${PREVIEW_ID}"

echo "=== Destroying preview: ${PREVIEW_ID} ==="

if [ -d "$PREVIEW_DIR" ]; then
    cd "$PREVIEW_DIR"
    docker compose down --remove-orphans --volumes 2>&1
    cd ~
    sudo rm -rf "$PREVIEW_DIR"
fi

docker exec shared-mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null

echo "=== Preview destroyed ==="
