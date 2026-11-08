#!/usr/bin/env bash
# The browse window ("Summon Browse Notes"): its list, keyboard, ⌘K and preview, measured in a real
# WKWebView at the reference's 750×474, then again resized, because the window can be.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--skip-editor" ]]; then
	echo "==> Building the editor bundle"
	(cd Editor && node build.mjs >/dev/null)
fi

echo "==> Running the browse suite"
swift Scripts/editor-probe.swift "$PWD/Editor/dist/browse.html" "$PWD/Editor/tests/browse.test.js" 750 474

echo "==> Running the resized browse suite"
exec swift Scripts/editor-probe.swift "$PWD/Editor/dist/browse.html" "$PWD/Editor/tests/browse-resized.test.js" 1280 800
