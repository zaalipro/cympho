// Run with: node --test test/js/details_menus_test.mjs
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(new URL("../../assets/js/app.js", import.meta.url), "utf8");
const start = source.indexOf("// The <details> menus a LiveView renders");
const end = source.indexOf("// Company rail controls.", start);
assert.ok(start >= 0 && end > start, "the details menus block is present");

function load() {
  const listeners = {};
  const queried = [];
  const menus = [{open: true}, {open: true}].map((menu) => ({
    ...menu,
    removeAttribute(name) {
      if (name === "open") this.open = false;
    }
  }));
  const context = {
    document: {
      querySelectorAll(selector) {
        queried.push(selector);
        return menus;
      }
    },
    window: {
      addEventListener(name, handler) {
        listeners[name] = handler;
      }
    }
  };
  vm.runInNewContext(
    `${source.slice(start, end)}\nglobalThis.__t = {DETAILS_MENUS, ServerOpen};`,
    context
  );
  return {...context.__t, listeners, queried, menus};
}

test("a live navigation (a patch, Back, Forward) closes the open details menus", () => {
  const {DETAILS_MENUS, listeners, queried, menus} = load();
  assert.equal(typeof listeners["phx:navigate"], "function");

  listeners["phx:navigate"]({detail: {patch: true, pop: true}});

  assert.deepEqual(queried, [DETAILS_MENUS]);
  for (const menu of [".rail details", "details.cympho-menu", "details.bc-mv", "details.ob-acct", "details.help-pop"]) {
    assert.ok(DETAILS_MENUS.includes(menu), `${menu} closes`);
  }
  assert.deepEqual(menus.map((menu) => menu.open), [false, false]);
});

test("ServerOpen keeps the reader's toggle and follows a change of the server's value", () => {
  const {ServerOpen} = load();
  const el = {dataset: {open: "false"}, open: false};
  const hook = Object.assign(Object.create(ServerOpen), {el});
  hook.mounted();

  el.open = true; // the reader opens it
  hook.updated(); // an unrelated update
  assert.equal(el.open, true);

  el.dataset.open = "true"; // a run fails
  hook.updated();
  assert.equal(el.open, true);

  el.open = false; // the reader closes it
  hook.updated();
  assert.equal(el.open, false);

  el.dataset.open = "false"; // the state clears
  hook.updated();
  assert.equal(el.open, false);

  el.dataset.open = "true"; // and comes back
  hook.updated();
  assert.equal(el.open, true);

  el.dataset.open = "false";
  hook.updated();
  assert.equal(el.open, false);
});
