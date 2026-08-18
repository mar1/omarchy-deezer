#!/bin/sh
# Stores the Deezer access token in the user's GNOME Keyring (via
# secret-tool). The token is read from stdin so it never appears in `ps`
# output, mirroring how Omarchy Spotify persists its refresh token.
set -eu

app_id=${1:-}
if [ -z "$app_id" ]; then
  exit 2
fi

IFS= read -r access_token
if [ -z "$access_token" ]; then
  exit 3
fi

printf '%s' "$access_token" | secret-tool store \
  --label='Omarchy Deezer access token' \
  service quickshell-deezer \
  kind access-token \
  app-id "$app_id"
