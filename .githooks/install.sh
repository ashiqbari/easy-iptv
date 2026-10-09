#!/bin/sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
existing=$(git config --get core.hooksPath || true)
if [ -n "$existing" ] && [ "$existing" != '.githooks' ]; then
    printf 'Existing hooksPath (%s) was left unchanged. Integrate the test hook manually.\n' "$existing" >&2
    exit 1
fi

chmod +x "$repo_root/.githooks/pre-commit"
git config --local core.hooksPath .githooks
printf '%s\n' 'Installed EasyIPTV pre-commit tests for this checkout.'
