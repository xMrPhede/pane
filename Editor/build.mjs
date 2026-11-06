/*
 * Builds each page into ONE self-contained HTML file: the pane's editor at dist/index.html, and the
 * browse window at dist/browse.html.
 *
 * Single file on purpose. The bundle is loaded inside a WKWebView with no network access, so anything
 * that resolves at runtime — a CDN script, an external stylesheet, a web font, a source map fetch —
 * would not merely be slow, it would not load at all. Inlining makes that failure impossible rather
 * than merely unlikely, and it means the Swift side has exactly one file to serve.
 */

import { build, context } from "esbuild";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const watch = process.argv.includes("--watch");

/** Safari 17 is the engine in the WKWebView on macOS 14, which is the deployment target. */
const TARGET = "safari17";

/**
 * Two pages, two windows. They share the markdown rendering (the browse window previews notes with
 * the pane's own live-preview decorations), but nothing at runtime: each is its own document in its
 * own WKWebView, so each is its own bundle.
 */
const PAGES = [
  { entry: "src/main.ts", template: "src/index.html", out: "dist/index.html" },
  { entry: "src/browse/main.ts", template: "src/browse.html", out: "dist/browse.html" },
];

const shared = {
  bundle: true,
  // Nothing is written here — `write: false` keeps the outputs in memory so they can be inlined into
  // the HTML below. esbuild still needs somewhere to *name* them, and refuses to emit the CSS bundle
  // without it.
  outdir: resolve(root, "dist"),
  format: "iife",
  target: TARGET,
  platform: "browser",
  write: false,
  minify: !watch,
  // No source maps: they would be a second file the web view cannot fetch, and inlining them would
  // double the bundle for no benefit in a shipped panel.
  sourcemap: false,
  legalComments: "none",
  logLevel: "info",
  // The browse window's command icon, inlined like everything else: there is nothing to fetch it from.
  loader: { ".png": "dataurl" },
};

const optionsFor = (page) => ({ ...shared, entryPoints: [resolve(root, page.entry)] });

async function emit(page, result) {
  const js = result.outputFiles.find((f) => f.path.endsWith(".js"))?.text ?? "";
  const css = result.outputFiles.find((f) => f.path.endsWith(".css"))?.text ?? "";

  const template = await readFile(resolve(root, page.template), "utf8");
  const html = template
    .replace("__STYLES__", () => css)
    .replace("__SCRIPT__", () => js);

  await mkdir(resolve(root, "dist"), { recursive: true });
  await writeFile(resolve(root, page.out), html, "utf8");

  const kb = (n) => `${(n / 1024).toFixed(1)} kB`;
  console.log(
    `${page.out}  ${kb(Buffer.byteLength(html))}  (js ${kb(Buffer.byteLength(js))}, css ${kb(Buffer.byteLength(css))})`
  );
}

if (watch) {
  for (const page of PAGES) {
    const ctx = await context({
      ...optionsFor(page),
      plugins: [
        {
          name: "emit-html",
          setup(b) {
            b.onEnd(async (result) => {
              if (result.errors.length === 0) await emit(page, result);
            });
          },
        },
      ],
    });
    await ctx.watch();
  }
  console.log("watching…");
} else {
  for (const page of PAGES) await emit(page, await build(optionsFor(page)));
}
