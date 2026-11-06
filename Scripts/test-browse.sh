#!/usr/bin/env bash
# The browse window ("Summon Browse Notes"): its list, keyboard, ⌘K and preview, measured in a real
# WKWebView at the window's own 750×474: the page is laid out against that window, so a probe of
# any other size would be measuring one that does not exist.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--skip-editor" ]]; then
	echo "==> Building the editor bundle"
	(cd Editor && node build.mjs >/dev/null)
fi

echo "==> Running the browse suite"
exec swift Scripts/editor-probe.swift "$PWD/Editor/dist/browse.html" "$PWD/Editor/tests/browse.test.js" 750 474
