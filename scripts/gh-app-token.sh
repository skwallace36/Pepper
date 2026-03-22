#!/bin/bash
set -euo pipefail

# scripts/gh-app-token.sh — Generate a GitHub App installation token
# Usage: eval "$(./scripts/gh-app-token.sh)"
# Output: exports GH_TOKEN=ghs_... for the gh CLI

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Load app config from .env
if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  source "$REPO_ROOT/.env"
  set +a
fi

APP_ID="${GITHUB_APP_ID:?Set GITHUB_APP_ID in .env}"
INSTALL_ID="${GITHUB_APP_INSTALLATION_ID:?Set GITHUB_APP_INSTALLATION_ID in .env}"

# Retrieve private key from macOS Keychain
PEM=$(security find-generic-password -a "pepper-agent-app" -s "pepper-github-app-key" -w 2>/dev/null || true)
if [ -z "$PEM" ]; then
  echo "Error: GitHub App private key not found in Keychain." >&2
  echo "Run: security add-generic-password -a pepper-agent-app -s pepper-github-app-key -w \"\$(cat key.pem)\"" >&2
  exit 1
fi

# Write PEM to temp file (openssl dgst -sign requires a file)
KEY_FILE=$(mktemp)
trap 'rm -f "$KEY_FILE"' EXIT
echo "$PEM" > "$KEY_FILE"

# Build JWT (RS256, 10-minute expiry)
NOW=$(date +%s)
IAT=$((NOW - 60))   # 60s clock-skew buffer (GitHub recommendation)
EXP=$((NOW + 600))

b64url() {
  openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
}

HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '{"iss":"%s","iat":%d,"exp":%d}' "$APP_ID" "$IAT" "$EXP" | b64url)
SIGNATURE=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | \
  openssl dgst -sha256 -sign "$KEY_FILE" -binary | b64url)

JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

# Exchange JWT for installation access token
RESPONSE=$(curl -sf -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" 2>/dev/null) || {
  echo "Error: GitHub API request failed." >&2
  exit 1
}

TOKEN=$(echo "$RESPONSE" | jq -r '.token // empty')
if [ -z "$TOKEN" ]; then
  echo "Error: No token in response." >&2
  echo "$RESPONSE" | jq . >&2
  exit 1
fi

echo "export GH_TOKEN=$TOKEN"
