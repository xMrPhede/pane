/*
 * The browse window resized: the same page at 1280×800, the size a window manager might give it.
 *
 * The window is resizable with no maximum, and the page has to spend the extra room where it is of
 * use: height to the list and the preview, width to the preview. Everything measured off the
 * reference keeps its size and its distance from the edge it hangs from. A second probe because the
 * rules read the viewport: the only way to test another size is another window.
 */

const W = 1280;
const H = 800;

function rows() {
  return Array.from({ length: 30 }, (_, i) => ({
    filename: `n${i}.md`,
    title: `Note ${i}`,
    section: i < 3 ? "Today" : "Older",
    modified: "Today at 6:31:46 PM",
    created: i === 1 ? null : "Today at 11:00:00 AM",
    available: true,
  }));
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

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
  const rect = (selector) => doc.querySelector(selector).getBoundingClientRect();

  expect("the probe window is the resized size", [window.innerWidth, window.innerHeight], [W, H]);

  const host = window.browseHost;
  host.applySettings({ appearance: "dark", translucent: true });
  host.reset();
  host.showNotes(rows(), "");
  host.showPreview("n0.md", "# Heading\n\nSome text.\n");
  await wait(50);

  // ---- what keeps its reference size -----------------------------------------------------------
  const list = rect("#list");
  near("the list keeps its 283 width", list.width, 283);
  near("and runs the full height under the search", list.height, H - 55);
  near("a row is still 38 tall", rect('.browse__row[aria-selected="true"]').height, 38);

  // ---- what takes the extra room ---------------------------------------------------------------
  const preview = rect("#preview");
  near("the preview takes the rest of the width", preview.left, 284);
  near("to the right edge", preview.right, W);
  const info = rect("#info");
  near("the Information block hangs 74 above the bottom edge", H - info.bottom, 74);
  near("at its own height", info.height, 106);
  near("and the preview runs down to 7 above it", info.top - preview.bottom, 7);

  // A note without a Created row must not move the block as the selection passes over it.
  doc.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", code: "ArrowDown", bubbles: true, cancelable: true }));
  expect("the selected note has no Created row", doc.getElementById("info-created-row").hidden, true);
  near("and the block has not moved", rect("#info").top, info.top);

  // ---- the floating bar ------------------------------------------------------------------------
  const left = rect(".browse__pill--title");
  const right = rect(".browse__pill--actions");
  near("the left pill stays 8 from the left edge", left.left, 8);
  near("the right pill stays 9 from the right edge", W - right.right, 9);
  near("both 9 above the bottom edge", H - right.bottom, 9);
  expect("the left pill names the app", left.width > 0 && doc.querySelector(".browse__pill--title span").textContent, "Pane");

  // ---- a resize keeps the selection in view ----------------------------------------------------
  for (let i = 0; i < 25; i++) {
    doc.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", code: "ArrowDown", bubbles: true, cancelable: true }));
  }
  await wait(30);
  const selected = rect('.browse__row[aria-selected="true"]');
  checked += 1;
  if (selected.bottom > left.top) failures.push({ case: "the selection scrolls clear of the bar", want: `≤ ${left.top}`, got: selected.bottom });

  // ---- nothing to list -------------------------------------------------------------------------
  host.reset();
  host.showNotes([], "");
  const empty = rect("#empty");
  near("an empty vault's message is centred in the whole window", empty.left + empty.width / 2, W / 2);
  expect("with no divider beside it", getComputedStyle(doc.querySelector(".browse__divider")).display, "none");

  return { checked, failures };
}
