#!/bin/bash
set -euo pipefail

BRANCH_RAW="$1"
REPO_URL="$2"
REPO_NAME="$3"
PR_NUMBER="$4"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env"

# Generate CRAFT_SECURITY_KEY if not set
if [ -z "${CRAFT_SECURITY_KEY:-}" ]; then
    CRAFT_SECURITY_KEY=$(openssl rand -hex 16)
    echo "Generated CRAFT_SECURITY_KEY: ${CRAFT_SECURITY_KEY}"
fi
BASE_DOMAIN="${5:-preview.${SERVER_IP}.sslip.io}"
DUMP_PATH="$HOME/preview-system/template/baseline.sql.gz"

# Build unique preview ID from repo name + PR number
REPO_SLUG=$(echo "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
PREVIEW_ID="${REPO_SLUG}-pr-${PR_NUMBER}"
DB_NAME="craft_${PREVIEW_ID//-/_}"
DOMAIN="${PREVIEW_ID}.${BASE_DOMAIN}"
PREVIEW_DIR="$HOME/preview-system/previews/${PREVIEW_ID}"

echo "=== Launching preview: ${DOMAIN} ==="

# Tear down if exists
if [ -d "$PREVIEW_DIR" ]; then
    echo "Existing preview found, tearing down..."
    cd "$PREVIEW_DIR"
    docker compose down --remove-orphans 2>/dev/null || true
    cd ~
    sudo rm -rf "$PREVIEW_DIR"
fi

# Clone repo
mkdir -p "$PREVIEW_DIR"
git clone --depth 1 --branch "$BRANCH_RAW" "$REPO_URL" "$PREVIEW_DIR/src" 2>&1

# Copy and fill template
cp ~/preview-system/template/docker-compose.yml "$PREVIEW_DIR/docker-compose.yml"
sed -i "s/__BRANCH__/${PREVIEW_ID}/g" "$PREVIEW_DIR/docker-compose.yml"
sed -i "s/__DB_NAME__/${DB_NAME}/g" "$PREVIEW_DIR/docker-compose.yml"
sed -i "s/__DOMAIN__/${DOMAIN}/g" "$PREVIEW_DIR/docker-compose.yml"
sed -i "s/__MYSQL_ROOT_PASSWORD__/${MYSQL_ROOT_PASSWORD}/g" "$PREVIEW_DIR/docker-compose.yml"
sed -i "s/__CRAFT_SECURITY_KEY__/${CRAFT_SECURITY_KEY}/g" "$PREVIEW_DIR/docker-compose.yml"

# Drop existing DB if any
docker exec shared-mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null || true

# Create fresh database
docker exec shared-mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    -e "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null

# Import baseline dump (if available)
if [ -f "$DUMP_PATH" ]; then
    echo "Importing baseline database..."
    gunzip -c "$DUMP_PATH" | \
        docker exec -i shared-mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "${DB_NAME}" 2>/dev/null
    echo "Database imported."
else
    echo "No baseline dump found, starting with empty database."
fi

# Install composer dependencies
echo "Installing composer dependencies..."
docker run --rm -u "$(id -u):$(id -g)" -v "$PREVIEW_DIR/src:/app" -w /app \
    composer:latest install --no-interaction --no-dev --optimize-autoloader --ignore-platform-reqs 2>&1 || true

# Install npm dependencies and build front-end assets
if [ -f "$PREVIEW_DIR/src/package.json" ]; then
    echo "Installing npm dependencies and building assets..."
    docker run --rm -u "$(id -u):$(id -g)" -v "$PREVIEW_DIR/src:/app" -w /app \
        node:lts-alpine sh -c "npm install && npm run build" 2>&1 || true
else
    echo "No package.json found, skipping npm build."
fi

# Fix permissions for Craft CMS
chmod -R 777 "$PREVIEW_DIR/src/storage" 2>/dev/null || mkdir -p "$PREVIEW_DIR/src/storage" && chmod -R 777 "$PREVIEW_DIR/src/storage"
chmod -R 777 "$PREVIEW_DIR/src/web/cpresources" 2>/dev/null || mkdir -p "$PREVIEW_DIR/src/web/cpresources" && chmod -R 777 "$PREVIEW_DIR/src/web/cpresources"

# Start containers
cd "$PREVIEW_DIR"
docker compose up -d 2>&1

echo "Waiting for container..."
# Restart Traefik to pick up new container routing (workaround for stale routing bug)
docker restart traefik 2>/dev/null || true
sleep 10

# Install or migrate Craft
if [ -f "$DUMP_PATH" ]; then
    echo "Running migrations..."
    docker exec "craft-${PREVIEW_ID}" php craft migrate/all --interactive=0 2>/dev/null || true
    echo "Applying project config..."
    docker exec "craft-${PREVIEW_ID}" php craft project-config/apply --interactive=0 2>/dev/null || true
else
    echo "Running fresh Craft install..."
    docker exec "craft-${PREVIEW_ID}" php craft install \
        --username="${CRAFT_ADMIN_EMAIL}" \
        --email="${CRAFT_ADMIN_EMAIL}" \
        --password="${CRAFT_ADMIN_PASSWORD}" \
        --siteName="Preview" \
        --siteUrl="http://${DOMAIN}" \
        --language="en-US" \
        --interactive=0 2>/dev/null || true
fi

# Clear caches
docker exec "craft-${PREVIEW_ID}" php craft clear-caches/all --interactive=0 2>/dev/null || true

echo ""
echo "=== Preview live at: http://${DOMAIN} ==="
echo "=== Admin panel:     http://${DOMAIN}/admin ==="
