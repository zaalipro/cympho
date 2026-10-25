import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

// The `nav_badges` push redraws the Inbox count in the root layout (app.js);
// it must show the same text as the server render (nav_rail.ex).
const source = await readFile(new URL("../../assets/js/app.js", import.meta.url), "utf8");
const start = source.indexOf("function updateNavBadgeNodes(");
const end = source.indexOf("\n}\n", start) + 3;
assert.ok(start >= 0 && end > start, "updateNavBadgeNodes is present");

function fakeNode() {
  const attrs = new Map();
  return {
    textContent: "",
    setAttribute: (name, value) => attrs.set(name, String(value)),
    removeAttribute: (name) => attrs.delete(name),
    getAttribute: (name) => (attrs.has(name) ? attrs.get(name) : null)
  };
}

// The server-rendered badge: the number, the full count for screen readers, the spoken suffix.
function fakeBadge() {
  const num = fakeNode();
  const full = fakeNode();
  const classes = new Set();
  const badge = {
    ...fakeNode(),
    dataset: {},
    classList: {toggle: (name, on) => (on ? classes.add(name) : classes.delete(name))},
    querySelector: (selector) =>
      ({"[data-badge-num]": num, "[data-badge-full]": full})[selector] || null
  };
  return {badge, num, full, classes};
}

function run(count) {
  const node = fakeBadge();
  const context = {
    Number,
    Math,
    String,
    document: {querySelectorAll: () => [node.badge]}
  };
  vm.runInNewContext(`${source.slice(start, end)}\nupdateNavBadgeNodes('inbox', ${count});`, context);
  return node;
}

test("a count over 99 shows 99+ and keeps the full count for screen readers", () => {
  const {badge, num, full, classes} = run(201);

  assert.equal(num.textContent, "99+");
  assert.equal(num.getAttribute("aria-hidden"), "true");
  assert.equal(full.textContent, "201");
  assert.equal(badge.dataset.count, "201");
  assert.equal(classes.has("hidden"), false);
});

test("a count up to 99 shows the number itself", () => {
  const {num, full, badge} = run(99);

  assert.equal(num.textContent, "99");
  assert.equal(num.getAttribute("aria-hidden"), null);
  assert.equal(full.textContent, "");
  assert.equal(badge.dataset.count, "99");
});

test("zero hides the badge", () => {
  const {num, classes} = run(0);

  assert.equal(num.textContent, "");
  assert.equal(classes.has("hidden"), true);
});
