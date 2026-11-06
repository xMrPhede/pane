/*
 * The browse window ("Summon Browse Notes"), in a real WKWebView at its own 750×474.
 *
 * Driven by `Scripts/editor-probe.swift` like the other page suites, with no Swift host: the suite
 * plays Swift's part through `window.browseHost`, and reads what the page asked for from
 * `browseDebug.sent`. Geometry is asserted as painted rectangles, because the window was built to
 * match a reference measured in points, and a regression there is invisible to the DOM.
 */

const TODO = "# TODO BUSINESS\n- [ ] Store\n\t- [ ] Hero Video\n- [x] Done thing\n";

function rows() {
  const today = ["UTM LINK IN BIO sui social", "Cool Things to checkout"];
  const older = ["TODO BUSINESS", "Riunione di condominio", "Personal", "CP todo:", "PROMPT PRESS WEBSITE",
    "AI STUFF", "Editing stuff", "Duration: 15 minutes", "Z-Statics Platform features:", "Shopping"];
  return [
    ...today.map((title, i) => ({ filename: `t${i}.md`, title, section: "Today", modified: "Today at 6:31:46 PM", created: "Today at 11:00:00 AM", available: true })),
    ...older.map((title, i) => ({ filename: `o${i}.md`, title, section: "Older", modified: "Jul 26, 2026 at 4:13:20 PM", created: i === 1 ? null : "May 25, 2026 at 5:49:47 PM", available: i !== 2 })),
  ];
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

function key(doc, init) {
  doc.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));
}

export async function run(_view, _bar, doc) {
  const failures = [];
  let checked = 0;
  const expect = (name, got, want) => {
    checked += 1;
    if (JSON.stringify(got) !== JSON.stringify(want)) failures.push({ case: name, want, got });
  };
  const near = (name, got, want, tolerance = 1) => {
    checked += 1;
    if (!(Math.abs(got - want) <= tolerance)) failures.push({ case: name, want: `${want} ±${tolerance}`, got });
  };

  const host = window.browseHost;
  const debug = window.browseDebug;
  const lastSent = (type) => [...debug.sent].reverse().find((m) => m.type === type);
  const selectedRow = () => doc.querySelector('.browse__row[aria-selected="true"]');

  host.applySettings({ appearance: "dark", translucent: true });
  host.reset();
  expect("a sitting starts by asking for every note", lastSent("requestNotes"), { type: "requestNotes", query: "" });
  host.showNotes(rows(), "");
  await wait(50);

  // ---- list ------------------------------------------------------------------------------------
  expect("sections are drawn once each, in order",
    [...doc.querySelectorAll(".browse__section")].map((e) => e.textContent), ["Today", "Older"]);
  expect("the first note is selected", selectedRow()?.textContent, "UTM LINK IN BIO sui social");
  expect("and its preview is asked for", lastSent("requestPreview"), { type: "requestPreview", filename: "t0.md" });
  expect("the Information block names it", doc.getElementById("info-title").textContent, "UTM LINK IN BIO sui social");
  expect("with both dates", doc.getElementById("info-modified").textContent, "Today at 6:31:46 PM");

  const list = doc.getElementById("list").getBoundingClientRect();
  near("the list column is 283 wide", list.width, 283);
  near("and starts under the 55pt search bar", list.top, 55);
  const sel = selectedRow().getBoundingClientRect();
  near("a row is 38 tall", sel.height, 38);
  near("the selection starts 7 in", sel.left, 7);
  near("and ends 7 short of the divider", sel.right, 276);
  near("the first row sits under its section header", sel.top, 55 + 32);

  // ---- keyboard --------------------------------------------------------------------------------
  key(doc, { key: "ArrowDown", code: "ArrowDown" });
  expect("↓ selects the next note", selectedRow()?.textContent, "Cool Things to checkout");
  key(doc, { key: "n", code: "KeyN", ctrlKey: true });
  expect("⌃N does too", selectedRow()?.textContent, "TODO BUSINESS");
  key(doc, { key: "ArrowUp", code: "ArrowUp" });
  key(doc, { key: "ArrowUp", code: "ArrowUp" });
  key(doc, { key: "ArrowUp", code: "ArrowUp" });
  expect("↑ stops at the top", selectedRow()?.textContent, "UTM LINK IN BIO sui social");

  for (let i = 0; i < 11; i++) key(doc, { key: "ArrowDown", code: "ArrowDown" });
  await wait(30);
  const last = selectedRow().getBoundingClientRect();
  const bar = doc.querySelector(".browse__bar").getBoundingClientRect();
  expect("↓ stops at the last note", selectedRow()?.textContent, "Shopping");
  checked += 1;
  if (last.bottom > bar.top) failures.push({ case: "the selected row scrolls clear of the action bar", want: `bottom ≤ ${bar.top}`, got: last.bottom });

  // A note iCloud has not downloaded has a row, and says so instead of asking for text it lacks.
  // A new sitting first: the same list sent again would keep the place it is at (tested below).
  host.reset();
  host.showNotes(rows(), "");
  expect("a new sitting starts at the top again", selectedRow()?.textContent, "UTM LINK IN BIO sui social");
  key(doc, { key: "ArrowDown", code: "ArrowDown" });
  key(doc, { key: "ArrowDown", code: "ArrowDown" });
  key(doc, { key: "ArrowDown", code: "ArrowDown" });
  key(doc, { key: "ArrowDown", code: "ArrowDown" });
  expect("an evicted note shows a placeholder", doc.getElementById("placeholder").textContent, "Downloading from iCloud…");
  key(doc, { key: "ArrowUp", code: "ArrowUp" });
  expect("a hand-named note has no Created row", doc.getElementById("info-created-row").hidden, true);

  key(doc, { key: "Enter", code: "Enter" });
  expect("↵ opens the selected note", lastSent("open"), { type: "open", filename: "o1.md" });

  // ---- a refresh keeps your place --------------------------------------------------------------
  host.refresh();
  host.showNotes(rows(), "");
  expect("a refresh of the same list keeps the selection", selectedRow()?.textContent, "Riunione di condominio");

  // ---- preview ---------------------------------------------------------------------------------
  key(doc, { key: "ArrowUp", code: "ArrowUp" });
  host.showPreview("o0.md", TODO);
  await wait(60);
  const heading = doc.querySelector(".browse__preview .pane-line-h1");
  const box = doc.querySelector(".browse__preview .pane-task");
  expect("the preview renders the heading", heading?.textContent, "TODO BUSINESS");
  if (heading && box) {
    const range = doc.createRange();
    const text = [...heading.querySelectorAll("*"), heading].flatMap((n) => [...n.childNodes]).find((n) => n.nodeType === 3 && n.textContent.trim());
    range.setStart(text, 0);
    range.setEnd(text, 1);
    near("a heading lines up with the checkbox under it", range.getBoundingClientRect().left, box.getBoundingClientRect().left, 2);
    expect("a preview checkbox cannot be pressed", getComputedStyle(box).pointerEvents, "none");
  }
  host.showPreview("t0.md", "stale answer for another note");
  expect("a preview for a note no longer selected is ignored", doc.querySelector(".browse__preview .pane-line-h1")?.textContent, "TODO BUSINESS");

  // ---- the action bar floats over the list -----------------------------------------------------
  const pill = doc.querySelector(".browse__pill--title").getBoundingClientRect();
  const hit = doc.elementFromPoint(pill.left + pill.width / 2, pill.top + pill.height / 2);
  expect("the command pill is on top of the list", Boolean(hit?.closest(".browse__pill")), true);
  near("the pills are 35 tall", pill.height, 35);
  near("and sit 9 above the bottom edge", window.innerHeight - pill.bottom, 9);

  // ---- ⌘K --------------------------------------------------------------------------------------
  key(doc, { key: "k", code: "KeyK", metaKey: true });
  const actions = doc.getElementById("actions");
  expect("⌘K opens the actions", actions.hidden, false);
  expect("listing what can be done to the note",
    [...doc.querySelectorAll(".browse__action-label")].map((e) => e.textContent),
    ["Open Note", "Copy Note as Markdown", "Reveal in Finder", "Pin Note", "Create Note", "Delete Note"]);
  expect("with the keys in force", [...doc.querySelectorAll(".browse__action")][1].querySelector(".browse__action-keys").textContent, "⇧⌘C");
  const search = doc.getElementById("actions-search");
  search.value = "del";
  search.dispatchEvent(new Event("input"));
  expect("typing filters them", [...doc.querySelectorAll(".browse__action-label")].map((e) => e.textContent), ["Delete Note"]);
  key(doc, { key: "Enter", code: "Enter" });
  expect("↵ runs the chosen action", lastSent("delete"), { type: "delete", filename: "o0.md" });
  expect("and closes the panel", actions.hidden, true);
  host.showNotes(rows().filter((r) => r.filename !== "o0.md"), "");
  expect("the neighbour below takes the selection", selectedRow()?.textContent, "Riunione di condominio");

  key(doc, { key: "c", code: "KeyC", metaKey: true, shiftKey: true });
  expect("an action's own key works without opening ⌘K", lastSent("copy"), { type: "copy", filename: "o1.md" });
  host.applySettings({ shortcuts: { copyAsMarkdown: "Alt-Mod-c" } });
  key(doc, { key: "ç", code: "KeyC", metaKey: true, altKey: true });
  expect("and follows a rebinding", debug.sent.filter((m) => m.type === "copy").length, 2);

  // ---- search and the empty state --------------------------------------------------------------
  const input = doc.getElementById("search");
  input.value = "nothing matches";
  input.dispatchEvent(new Event("input"));
  await wait(40);
  expect("typing asks for a search", lastSent("requestNotes"), { type: "requestNotes", query: "nothing matches" });
  host.showNotes(rows(), "a stale query");
  expect("an answer to an older query is ignored", doc.querySelectorAll(".browse__row").length, 11);
  host.showNotes([], "nothing matches");
  expect("no results says so", doc.getElementById("empty-title").textContent, "No Results");
  expect("and ↵ becomes Create Note", doc.getElementById("primary-label").textContent, "Create Note");
  expect("the Information block goes away", doc.getElementById("info").hidden, true);
  key(doc, { key: "Enter", code: "Enter" });
  expect("↵ creates a note named after the search", lastSent("create"), { type: "create", title: "nothing matches" });

  key(doc, { key: "Escape", code: "Escape" });
  expect("Esc first empties the search", input.value, "");
  const closes = debug.sent.filter((m) => m.type === "close").length;
  key(doc, { key: "Escape", code: "Escape" });
  expect("and only then closes", debug.sent.filter((m) => m.type === "close").length, closes + 1);

  return { checked, failures };
}
