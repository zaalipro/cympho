import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

// C3: on phones a toast sits in the band just above the tab bar (app.css). A bottom action bar
// stuck there (.sticky-above-mobile-nav) owns that band, so the Toast hook (app.js) lifts the
// toast above it, as Material's snackbar is nudged above a docked toolbar.
const source = await readFile(new URL("../../assets/js/app.js", import.meta.url), "utf8");
const start = source.indexOf("const Toast = {");
const end = source.indexOf("\n};\n", start) + 4;
assert.ok(start >= 0 && end > start, "the Toast hook is present");

const VIEWPORT = 844;
// app.css puts the phone band's bottom edge 4 px above the tab bar (top 770).
const BAND_BOTTOM = 766;

function rect(top, bottom) {
  return {top, bottom, height: bottom - top};
}

function show({phone = true, bars = []} = {}) {
  const appended = [];
  const container = {
    style: {bottom: ""},
    appendChild: (el) => appended.push(el),
    getBoundingClientRect() {
      const bottom = this.style.bottom ? VIEWPORT - parseFloat(this.style.bottom) : BAND_BOTTOM;
      return {top: bottom, bottom, height: 0};
    }
  };

  const context = {
    Date,
    window: {innerHeight: VIEWPORT, matchMedia: () => ({matches: phone})},
    document: {
      getElementById: (id) => (id === "toast-container" ? container : null),
      querySelectorAll: (selector) =>
        selector === ".sticky-above-mobile-nav"
          ? bars.map((r) => ({getBoundingClientRect: () => r}))
          : [],
      createElement: () => ({className: "", textContent: "", classList: {add() {}, remove() {}}})
    },
    requestAnimationFrame: () => {},
    setTimeout: () => 1
  };

  const toast = vm.runInNewContext(`${source.slice(start, end)}\nToast`, context);
  toast._queue = [];
  toast._activeToasts = [];
  toast._enqueue("Answer sent.", "success");

  assert.equal(appended.length, 1, "the toast is shown");
  return container;
}

test("on a phone a stuck bottom action bar lifts the toast above it", () => {
  // New task's bar, stuck on the tab bar's top edge
  const container = show({bars: [rect(700, 770)]});

  assert.equal(container.style.bottom, `${VIEWPORT - 700 + 4}px`);
});

test("a bar elsewhere on the page or hidden leaves the toast in its band", () => {
  assert.equal(show({bars: [rect(300, 370)]}).style.bottom, "");
  assert.equal(show({bars: [rect(0, 0)]}).style.bottom, "");
  assert.equal(show({bars: [rect(900, 970)]}).style.bottom, "");
});

test("a lift from an earlier toast is dropped once the bar is gone", () => {
  const container = show({bars: [rect(700, 770)]});
  assert.notEqual(container.style.bottom, "");

  // the same container, the bar has scrolled away
  const context = {
    window: {innerHeight: VIEWPORT, matchMedia: () => ({matches: true})},
    document: {querySelectorAll: () => []}
  };
  const toast = vm.runInNewContext(`${source.slice(start, end)}\nToast`, context);
  toast._clearStickyBar(container);

  assert.equal(container.style.bottom, "");
});

test("on wider screens the toast keeps its bottom-right corner", () => {
  assert.equal(show({phone: false, bars: [rect(700, 770)]}).style.bottom, "");
});
