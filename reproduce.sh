#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Clean slate
rm -rf .git test.txt
git init
git commit --allow-empty -m "initial commit"
hk install

# Stage a file so pre-commit has work to do
echo "hello world" > test.txt
git add test.txt

echo ""
echo "=== Without hkrc: pre-commit works fine ==="
hk run pre-commit || true

echo ""
echo "=== With hkrc: panics ==="
echo "hk deserializes hkrc as UserConfig (not Config), so"
echo "Step.check (a string) hits UserHookConfig.check (a bool)."
echo ""
hk --hkrc global-hkrc.pkl run pre-commit
