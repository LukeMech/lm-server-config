#!/bin/bash
#
# Renders a package-changes TSV (kind<TAB>name<TAB>previous<TAB>new, kind one of
# added/updated/removed, '-' for a missing side) as the changelog's markdown tables.
# Shared by diff-packages.sh (one image) and merge-changelogs.sh (the release's
# "All images" section plus each image's remainder).
#
# An empty TSV renders as "No package changes." -- or <empty-text> if given.
#
# Usage: render-package-changes.sh <changes.tsv> [empty-text]

set -euo pipefail

TSV="${1:?usage: $0 <changes.tsv> [empty-text]}"
EMPTY_TEXT="${2:-No package changes.}"

echo "## 📦 Package changes"
echo

if [[ ! -s "${TSV}" ]]; then
    echo "${EMPTY_TEXT}"
    echo
    exit 0
fi

# Only the buckets that have rows -- a release with only updates doesn't show
# empty headers.
if grep -q $'^added\t' "${TSV}"; then
    echo "### ✨ Added"
    echo
    echo "| Package | Version |"
    echo "|---|---|"
    awk -F'\t' '$1 == "added" { printf "| %s | %s |\n", $2, $4 }' "${TSV}"
    echo
fi

if grep -q $'^updated\t' "${TSV}"; then
    echo "### 🔄 Updated"
    echo
    echo "| Package | Previous | New |"
    echo "|---|---|---|"
    awk -F'\t' '$1 == "updated" { printf "| %s | %s | %s |\n", $2, $3, $4 }' "${TSV}"
    echo
fi

if grep -q $'^removed\t' "${TSV}"; then
    echo "### ❌ Removed"
    echo
    echo "| Package | Version |"
    echo "|---|---|"
    awk -F'\t' '$1 == "removed" { printf "| %s | %s |\n", $2, $3 }' "${TSV}"
    echo
fi
