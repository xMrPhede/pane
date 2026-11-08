/*
 * The browse window's web layer: Pane's "Summon Browse Notes" hotkey.
 *
 * A second, much smaller page than the pane's. It lists the vault on the left, renders the selected
 * note on the right with the same live-preview decorations the pane draws (read-only, never
 * focused, so nothing is ever revealed raw), and floats an action bar over the bottom edge.
 *
 * Owns no truth, exactly like the pane's page (decision 4): rows, preview text and settings arrive
 * from Swift through `window.browseHost`, and every intent goes back through
 * `webkit.messageHandlers.browse`. Ordering, sectioning and date strings are decided in PaneKit
 * (`NoteBrowser`), where they are tested.
 */

import "../styles/tokens.css";
import "../styles/markdown.css";
import "../styles/browse.css";

import { html } from "@codemirror/lang-html";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState, type Extension } from "@codemirror/state";
import { EditorView } from "@codemirror/view";

import { paneDialect } from "../dialect";
import { livePreview } from "../live-preview";
import paneIcon from "./pane-icon.png";

// ---------------------------------------------------------------------------------------------
// Bridge
// ---------------------------------------------------------------------------------------------

/** Mirrors `BrowseRow` in `PaneKit/NoteBrowser.swift`. */
export interface BrowseRow {
  filename: string;
  title: string;
  section: string;
  pinned?: boolean;
  modified: string;
  created?: string | null;
  available: boolean;
}

type OutboundMessage =
  | { type: "ready" }
  | { type: "requestNotes"; query: string }
  | { type: "requestPreview"; filename: string }
  | { type: "open"; filename: string }
  | { type: "create"; title: string }
  | { type: "close" }
  | { type: "copy"; filename: string }
  | { type: "reveal"; filename: string }
  | { type: "togglePin"; filename: string }
  | { type: "delete"; filename: string }
  | { type: "openLink"; target: string };

declare global {
  interface Window {
    browseHost: typeof host;
  }
}

/** This page's handler. Typed locally: `Window.webkit` is already declared by the pane's page. */
const bridge = (window as unknown as {
  webkit?: { messageHandlers?: { browse?: { postMessage(message: unknown): void } } };
}).webkit?.messageHandlers?.browse;

/** The last few messages sent, for the probe suite, which runs the page with no Swift host. */
const sent: OutboundMessage[] = [];

function send(message: OutboundMessage): void {
  sent.push(message);
  if (sent.length > 50) sent.shift();
  // Absent when the page is opened directly in a browser for design work: degrade, never throw.
  bridge?.postMessage(message);
}

// ---------------------------------------------------------------------------------------------
// Elements
// ---------------------------------------------------------------------------------------------

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const rootEl = $("browse");
const searchEl = $<HTMLInputElement>("search");
const listEl = $("list");
const emptyEl = $("empty");
const emptyTitleEl = $("empty-title");
const emptyHintEl = $("empty-hint");
const previewEl = $("preview");
const placeholderEl = $("placeholder");
const infoEl = $("info");
const infoTitleEl = $("info-title");
const infoModifiedEl = $("info-modified");
const infoCreatedEl = $("info-created");
const infoCreatedRowEl = $("info-created-row");
const primaryEl = $("primary");
const primaryLabelEl = $("primary-label");
const actionsButtonEl = $("actions-button");
const actionsEl = $("actions");
const actionsListEl = $("actions-list");
const actionsSearchEl = $<HTMLInputElement>("actions-search");
const toastEl = $("toast");
$<HTMLImageElement>("app-icon").src = paneIcon;

// ---------------------------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------------------------

let rows: BrowseRow[] = [];
let selected = -1;
/** The filename the selection should land on after the next render, which keeps it put across a refresh. */
let keepSelection: string | null = null;
let previewFor: string | null = null;
let lastQuery = "";
/** The query the list on screen answers; null before the first answer of a sitting. */
let renderedQuery: string | null = null;

/** The in-pane shortcuts, so the ⌘K rows print and obey the bindings in force rather than literals. */
const DEFAULT_SHORTCUTS: Record<string, string> = {
  copyAsMarkdown: "Shift-Mod-c",
  revealInFinder: "Alt-Mod-r",
  pinPane: "Shift-Mod-p",
  deleteNote: "Ctrl-x",
  newNote: "Mod-n",
};
let shortcuts: Record<string, string> = { ...DEFAULT_SHORTCUTS };

// ---------------------------------------------------------------------------------------------
// Preview: the pane's own rendering, read-only
// ---------------------------------------------------------------------------------------------

function previewExtensions(): Extension[] {
  return [
    EditorState.readOnly.of(true),
    EditorView.editable.of(false),
    EditorView.lineWrapping,
    markdown({
      base: markdownLanguage,
      extensions: paneDialect,
      addKeymap: false,
      htmlTagLanguage: html({ matchClosingTags: false, autoCloseTags: false }),
    }),
    // ⌘-click on a link opens it, as it does in the pane; Swift decides what may be opened.
    livePreview((target) => send({ type: "openLink", target })),
    EditorView.theme({
      "&": { height: "100%" },
      ".cm-scroller": { fontFamily: "var(--font-ui)", lineHeight: "var(--line-height)" },
    }),
  ];
}

const preview = new EditorView({
  parent: previewEl,
  state: EditorState.create({ doc: "", extensions: previewExtensions() }),
});

function showPreviewText(text: string): void {
  // A fresh state rather than a replacing transaction: it resets the scroll to the top and carries
  // no history, which is what moving to another note in a list should do.
  preview.setState(EditorState.create({ doc: text, extensions: previewExtensions() }));
  previewEl.hidden = false;
  placeholderEl.hidden = true;
}

function showPlaceholder(text: string): void {
  preview.setState(EditorState.create({ doc: "", extensions: previewExtensions() }));
  previewEl.hidden = true;
  placeholderEl.hidden = false;
  placeholderEl.textContent = text;
}

// ---------------------------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------------------------

const DOC_ICON = `<svg class="browse__row-icon" width="15" height="17" viewBox="0 0 14 16" aria-hidden="true"><path class="doc-icon" d="M2.75 1.25h5.5L11.75 4.75v9a1 1 0 0 1-1 1h-8a1 1 0 0 1-1-1v-12.5a1 1 0 0 1 1-1Z M8 1.5v3.5h3.5"/></svg>`;
const PIN_ICON = `<svg class="browse__row-pin" width="12" height="12" viewBox="0 0 14 14" aria-hidden="true"><circle cx="7" cy="5" r="3" fill="none" stroke="currentColor" stroke-width="1.5"/><line x1="7" y1="8" x2="7" y2="13" stroke="currentColor" stroke-width="1.5"/></svg>`;

function render(): void {
  listEl.replaceChildren();
  let section: string | null = null;

  rows.forEach((row, index) => {
    if (row.section !== section) {
      section = row.section;
      const header = document.createElement("div");
      header.className = "browse__section";
      header.textContent = row.section;
      listEl.appendChild(header);
    }

    const el = document.createElement("div");
    el.className = "browse__row";
    el.setAttribute("role", "option");
    el.dataset.index = String(index);
    el.innerHTML = DOC_ICON;

    const title = document.createElement("span");
    title.className = "browse__row-title";
    title.textContent = row.title;
    el.appendChild(title);

    if (row.pinned) el.insertAdjacentHTML("beforeend", PIN_ICON);

    el.addEventListener("mousedown", (event) => {
      event.preventDefault(); // keep the caret in the search field
      select(index, false);
    });
    el.addEventListener("dblclick", () => openSelected());
    listEl.appendChild(el);
  });

  const empty = rows.length === 0;
  emptyEl.hidden = !empty;
  // Nothing to list means nothing to preview: the message takes the whole window, not the list's
  // column beside an empty half.
  rootEl.toggleAttribute("data-empty", empty);
  if (empty) {
    const query = searchEl.value.trim();
    emptyTitleEl.textContent = query ? "No Results" : "No Notes";
    emptyHintEl.textContent = query
      ? `Press ↵ to create a note called “${query}”`
      : "Press ↵ to create your first note";
  }
  primaryLabelEl.textContent = empty ? "Create Note" : "Open Note";
}

function rowElement(index: number): HTMLElement | null {
  return listEl.querySelector<HTMLElement>(`.browse__row[data-index="${index}"]`);
}

/** What the floating action bar covers at the bottom of the list, plus the fade above it. */
const BOTTOM_CLEARANCE = 52;

function select(index: number, scroll = true): void {
  if (rows.length === 0) {
    selected = -1;
    previewFor = null;
    infoEl.hidden = true;
    showPlaceholder("");
    return;
  }

  const next = Math.max(0, Math.min(rows.length - 1, index));
  rowElement(selected)?.removeAttribute("aria-selected");
  selected = next;
  const el = rowElement(selected);
  el?.setAttribute("aria-selected", "true");
  if (el && scroll) scrollIntoView(el);

  const row = rows[selected]!;
  infoEl.hidden = false;
  infoTitleEl.textContent = row.title;
  infoModifiedEl.textContent = row.modified;
  infoCreatedRowEl.hidden = !row.created;
  infoCreatedEl.textContent = row.created ?? "";

  if (previewFor !== row.filename) {
    previewFor = row.filename;
    if (row.available) {
      send({ type: "requestPreview", filename: row.filename });
    } else {
      showPlaceholder("Downloading from iCloud…");
    }
  }
}

function scrollIntoView(el: HTMLElement): void {
  const top = el.offsetTop;
  const bottom = top + el.offsetHeight;
  // The first row of a section brings its header with it, so a section never scrolls in nameless.
  const header = el.previousElementSibling?.classList.contains("browse__section")
    ? (el.previousElementSibling as HTMLElement)
    : null;
  const wantedTop = header ? header.offsetTop : top;
  const viewTop = listEl.scrollTop;
  const viewBottom = viewTop + listEl.clientHeight - BOTTOM_CLEARANCE;

  if (wantedTop < viewTop + 8) {
    listEl.scrollTop = Math.max(0, wantedTop - 8);
  } else if (bottom > viewBottom) {
    listEl.scrollTop = bottom - (listEl.clientHeight - BOTTOM_CLEARANCE);
  }
}

function openSelected(): void {
  const row = rows[selected];
  if (row) {
    send({ type: "open", filename: row.filename });
  } else {
    send({ type: "create", title: searchEl.value.trim() });
  }
}

// ---------------------------------------------------------------------------------------------
// Overlay scrollbar
// ---------------------------------------------------------------------------------------------

const thumbEl = $("scroll-thumb");
let thumbTimer = 0;

/** Places the thumb over the list's right edge. Shown while scrolling, faded out once it stops. */
function updateThumb(show: boolean): void {
  const { scrollTop, scrollHeight, clientHeight } = listEl;
  if (scrollHeight <= clientHeight + 1) {
    thumbEl.removeAttribute("data-active");
    return;
  }
  // The track stops short of the action bar, which floats over the list's last 54px.
  const trackTop = 4;
  const track = clientHeight - trackTop - 56;
  const height = Math.max(28, (track * clientHeight) / scrollHeight);
  const top = trackTop + ((track - height) * scrollTop) / (scrollHeight - clientHeight);
  thumbEl.style.top = `${top}px`;
  thumbEl.style.height = `${height}px`;
  if (!show) return;
  thumbEl.setAttribute("data-active", "");
  window.clearTimeout(thumbTimer);
  thumbTimer = window.setTimeout(() => thumbEl.removeAttribute("data-active"), 900);
}

listEl.addEventListener("scroll", () => updateThumb(true), { passive: true });

// The window is resizable: a shorter list must still show the selection, and the thumb's track
// follows the list's height.
window.addEventListener("resize", () => {
  const el = rowElement(selected);
  if (el) scrollIntoView(el);
  updateThumb(false);
});

let searchTimer = 0;
searchEl.addEventListener("input", () => {
  // One frame of coalescing: a fast typist's burst becomes one round trip, and nothing is lost.
  window.clearTimeout(searchTimer);
  searchTimer = window.setTimeout(() => {
    lastQuery = searchEl.value;
    keepSelection = null;
    send({ type: "requestNotes", query: lastQuery });
  }, 16);
});

// ---------------------------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------------------------

/** `KeyboardEvent` → the CodeMirror-style binding Pane stores: `Shift-Mod-c`. */
function bindingOf(event: KeyboardEvent): string {
  const parts: string[] = [];
  if (event.ctrlKey) parts.push("Ctrl");
  if (event.altKey) parts.push("Alt");
  if (event.shiftKey) parts.push("Shift");
  if (event.metaKey) parts.push("Mod");
  parts.push(keyName(event));
  return parts.join("-");
}

const CODE_KEYS: Record<string, string> = {
  Slash: "/", Comma: ",", Period: ".", Semicolon: ";", Quote: "'", BracketLeft: "[", BracketRight: "]",
  Backslash: "\\", Minus: "-", Equal: "=", Backquote: "`", Space: "Space",
};

function keyName(event: KeyboardEvent): string {
  // By physical key for letters, digits and punctuation, so ⇧ and ⌥ do not turn `c` into `C` or `ç`.
  if (event.code.startsWith("Key")) return event.code.slice(3).toLowerCase();
  if (event.code.startsWith("Digit")) return event.code.slice(5);
  return CODE_KEYS[event.code] ?? event.key;
}

/** Same comparison either way round: `Mod-Shift-c` and `Shift-Mod-c` are one binding. */
function sameBinding(a: string, b: string): boolean {
  const norm = (s: string) => {
    const parts = s.split("-");
    const key = parts.pop() ?? "";
    const mods = parts.map((p) => (p === "Cmd" || p === "Meta" ? "Mod" : p === "Control" ? "Ctrl" : p === "Option" ? "Alt" : p));
    return [...mods.sort(), key.toLowerCase()].join("-");
  };
  return norm(a) === norm(b);
}

document.addEventListener(
  "keydown",
  (event) => {
    if (!actionsEl.hidden) {
      handleActionsKey(event);
      return;
    }

    const binding = bindingOf(event);
    const ctrlOnly = event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey;

    if (event.key === "ArrowDown" || (ctrlOnly && (event.key === "n" || event.key === "j"))) {
      event.preventDefault();
      select(selected + 1);
      return;
    }
    if (event.key === "ArrowUp" || (ctrlOnly && (event.key === "p" || event.key === "k"))) {
      event.preventDefault();
      select(selected - 1);
      return;
    }
    if (event.key === "Enter" && !event.metaKey && !event.ctrlKey && !event.altKey && !event.isComposing) {
      event.preventDefault();
      openSelected();
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      // The reference's order: Esc first empties the search, and only an empty search closes.
      if (searchEl.value) {
        searchEl.value = "";
        searchEl.dispatchEvent(new Event("input"));
      } else {
        send({ type: "close" });
      }
      return;
    }
    if (binding === "Mod-k") {
      event.preventDefault();
      openActions();
      return;
    }
    if (binding === "Mod-w") {
      event.preventDefault();
      send({ type: "close" });
      return;
    }

    for (const action of actions()) {
      if (action.binding && sameBinding(binding, action.binding) && action.enabled) {
        event.preventDefault();
        action.run();
        return;
      }
    }
  },
  true
);

// The search field keeps the caret for the window's whole life: every key lands in it, which is what
// makes the window a thing you type at the moment it appears.
document.addEventListener("mousedown", (event) => {
  const target = event.target as HTMLElement;
  if (target === searchEl || target === actionsSearchEl) return;
  if (target.closest(".browse__preview")) return; // text in the preview may be selected
  event.preventDefault();
});

$("back").addEventListener("click", () => send({ type: "close" }));
primaryEl.addEventListener("click", () => openSelected());
actionsButtonEl.addEventListener("click", () => (actionsEl.hidden ? openActions() : closeActions()));

// ---------------------------------------------------------------------------------------------
// ⌘K
// ---------------------------------------------------------------------------------------------

interface Action {
  id: string;
  label: string;
  /** A CodeMirror-style binding, printed as keycaps and obeyed while the window is up. */
  binding?: string;
  /** Printed instead of `binding` when the key is not rebindable (↵). */
  keys?: string[];
  enabled: boolean;
  destructive?: boolean;
  run: () => void;
}

function actions(): Action[] {
  const row = rows[selected];
  const filename = row?.filename ?? "";
  const has = Boolean(row);
  return [
    { id: "open", label: "Open Note", keys: ["↵"], enabled: has, run: openSelected },
    {
      id: "copy", label: "Copy Note as Markdown", binding: shortcuts.copyAsMarkdown, enabled: has,
      run: () => send({ type: "copy", filename }),
    },
    {
      id: "reveal", label: "Reveal in Finder", binding: shortcuts.revealInFinder, enabled: has,
      run: () => send({ type: "reveal", filename }),
    },
    {
      id: "pin", label: row?.pinned ? "Unpin Note" : "Pin Note", binding: shortcuts.pinPane, enabled: has,
      run: () => {
        keepSelection = filename;
        send({ type: "togglePin", filename });
      },
    },
    {
      id: "new", label: "Create Note", binding: shortcuts.newNote, enabled: true,
      run: () => send({ type: "create", title: "" }),
    },
    {
      id: "delete", label: "Delete Note", binding: shortcuts.deleteNote, enabled: has, destructive: true,
      run: () => {
        // The neighbour below takes the selection, as it does in any list you delete from.
        keepSelection = rows[selected + 1]?.filename ?? rows[selected - 1]?.filename ?? null;
        send({ type: "delete", filename });
      },
    },
  ];
}

let actionIndex = 0;
let visibleActions: Action[] = [];

function openActions(): void {
  actionsSearchEl.value = "";
  actionIndex = 0;
  renderActions();
  actionsEl.hidden = false;
  actionsButtonEl.setAttribute("aria-pressed", "true");
  actionsSearchEl.focus();
}

function closeActions(): void {
  actionsEl.hidden = true;
  actionsButtonEl.removeAttribute("aria-pressed");
  searchEl.focus();
}

function renderActions(): void {
  const query = actionsSearchEl.value.trim().toLowerCase();
  visibleActions = actions().filter((a) => a.enabled && a.label.toLowerCase().includes(query));
  actionIndex = Math.max(0, Math.min(actionIndex, visibleActions.length - 1));
  actionsListEl.replaceChildren();

  visibleActions.forEach((action, index) => {
    const el = document.createElement("div");
    el.className = "browse__action";
    if (action.destructive) el.classList.add("browse__action--destructive");
    if (index === actionIndex) el.setAttribute("aria-selected", "true");
    el.setAttribute("role", "option");

    const label = document.createElement("span");
    label.className = "browse__action-label";
    label.textContent = action.label;
    el.appendChild(label);

    const keys = document.createElement("span");
    keys.className = "browse__action-keys";
    for (const cap of action.keys ?? keycaps(action.binding ?? "")) {
      const kbd = document.createElement("kbd");
      kbd.textContent = cap;
      keys.appendChild(kbd);
    }
    el.appendChild(keys);

    el.addEventListener("mousedown", (event) => {
      event.preventDefault();
      runAction(action);
    });
    el.addEventListener("mousemove", () => {
      if (actionIndex === index) return;
      actionIndex = index;
      renderActions();
    });
    actionsListEl.appendChild(el);
  });

  if (visibleActions.length === 0) {
    const none = document.createElement("div");
    none.className = "browse__action browse__action--none";
    none.textContent = "No matching actions";
    actionsListEl.appendChild(none);
  }
}

function runAction(action: Action): void {
  closeActions();
  action.run();
}

/** `Shift-Mod-c` → ["⇧", "⌘", "C"], in Apple's order. */
function keycaps(binding: string): string[] {
  if (!binding) return [];
  const parts = binding.split("-");
  const key = parts.pop() ?? "";
  const held = new Set(parts);
  const caps: string[] = [];
  if (held.has("Ctrl")) caps.push("⌃");
  if (held.has("Alt")) caps.push("⌥");
  if (held.has("Shift")) caps.push("⇧");
  if (held.has("Mod") || held.has("Cmd")) caps.push("⌘");
  caps.push(key.length === 1 ? key.toUpperCase() : key);
  return caps;
}

function handleActionsKey(event: KeyboardEvent): void {
  if (event.key === "Escape" || bindingOf(event) === "Mod-k") {
    event.preventDefault();
    closeActions();
    return;
  }
  if (event.key === "ArrowDown") {
    event.preventDefault();
    actionIndex = Math.min(visibleActions.length - 1, actionIndex + 1);
    renderActions();
    return;
  }
  if (event.key === "ArrowUp") {
    event.preventDefault();
    actionIndex = Math.max(0, actionIndex - 1);
    renderActions();
    return;
  }
  if (event.key === "Enter" && !event.isComposing) {
    event.preventDefault();
    const action = visibleActions[actionIndex];
    if (action) runAction(action);
    return;
  }
  const binding = bindingOf(event);
  for (const action of actions()) {
    if (action.binding && sameBinding(binding, action.binding) && action.enabled) {
      event.preventDefault();
      runAction(action);
      return;
    }
  }
}

actionsSearchEl.addEventListener("input", () => {
  actionIndex = 0;
  renderActions();
});

// ---------------------------------------------------------------------------------------------
// Toast
// ---------------------------------------------------------------------------------------------

let toastTimer = 0;
function showToast(text: string): void {
  toastEl.textContent = text;
  toastEl.hidden = false;
  toastEl.classList.remove("browse__toast--out");
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => {
    toastEl.classList.add("browse__toast--out");
    toastTimer = window.setTimeout(() => (toastEl.hidden = true), 200);
  }, 1600);
}

// ---------------------------------------------------------------------------------------------
// Host API (Swift → page)
// ---------------------------------------------------------------------------------------------

const themeStyleEl = document.createElement("style");
document.head.appendChild(themeStyleEl);

const host = {
  /** The window was summoned: a fresh sitting, an empty search, the first note selected. */
  reset(): void {
    closeActions();
    searchEl.value = "";
    lastQuery = "";
    renderedQuery = null;
    keepSelection = null;
    previewFor = null;
    listEl.scrollTop = 0;
    searchEl.focus();
    send({ type: "requestNotes", query: "" });
  },

  /** Rows for `query`. Ignored when the field has moved on since it was asked. */
  showNotes(next: BrowseRow[], query: string): void {
    if (query !== lastQuery) return;
    // A refresh of the list on screen keeps your place; a new search starts at its best result.
    const sameList = query === renderedQuery;
    const wanted = keepSelection ?? (sameList ? rows[selected]?.filename ?? null : null);
    const previousIndex = selected;
    rows = next;
    renderedQuery = query;
    keepSelection = null;
    render();

    let index = wanted ? rows.findIndex((r) => r.filename === wanted) : 0;
    // The note that was selected is gone (deleted elsewhere): stay at the same height in the list.
    if (index < 0) index = Math.max(0, Math.min(previousIndex, rows.length - 1));
    selected = -1;
    select(index);
  },

  showPreview(filename: string, text: string | null): void {
    if (filename !== rows[selected]?.filename) return;
    if (text === null) {
      showPlaceholder("This note can’t be previewed yet.");
    } else {
      showPreviewText(text);
    }
  },

  /** The list must be re-asked for: a pin, a delete, an external edit. */
  refresh(): void {
    // The text may be what changed, so the preview is asked for again too.
    previewFor = null;
    send({ type: "requestNotes", query: lastQuery });
  },

  showToast,

  applySettings(settings: {
    appearance?: string;
    accent?: string;
    translucent?: boolean;
    themeCSS?: string;
    shortcuts?: Record<string, string>;
  }): void {
    const root = document.documentElement;
    if (settings.appearance && settings.appearance !== "system") {
      root.setAttribute("data-appearance", settings.appearance);
    } else {
      root.removeAttribute("data-appearance");
    }
    root.setAttribute("data-vibrancy", settings.translucent === false ? "off" : "on");
    if (settings.accent) root.style.setProperty("--accent", settings.accent);
    if (settings.themeCSS !== undefined) themeStyleEl.textContent = settings.themeCSS;
    if (settings.shortcuts) shortcuts = { ...DEFAULT_SHORTCUTS, ...settings.shortcuts };
  },
};

window.browseHost = host;

// For the probe suite, which drives the page without a Swift host.
(window as unknown as { browseDebug: unknown }).browseDebug = {
  get rows() { return rows; },
  get selected() { return selected; },
  sent,
  preview,
};

searchEl.focus();
send({ type: "ready" });
