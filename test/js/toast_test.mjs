import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

// C3: a toast sat over the page's buttons at the fold ("Send answer", "Open vote"), and on
// phones a CSS rule hid all but the newest while the hidden ones timed out unseen. The Toast
// hook (app.js) shows one toast at a time on phones, each for its full time, and gives the
// toasts a lane: --toast-lane, which app.css turns into the page scroller's bottom margin.
const source = await readFile(new URL("../../assets/js/app.js", import.meta.url), "utf8");
const start = source.indexOf("const Toast = {");
const end = source.indexOf("\n};\n", start) + 4;
assert.ok(start >= 0 && end > start, "the Toast hook is present");

const PHONE = {height: 844, bottom: 766, toast: 36, gap: 8};
const DESKTOP = {height: 900, bottom: 884, toast: 40, gap: 8};

// A fake page: the container stacks its toasts up from its bottom edge, and the clock only
// moves when the test says so.
function page({phone = true, toastHeight} = {}) {
  const view = phone ? PHONE : DESKTOP;
  const height = toastHeight || view.toast;
  let now = 0;
  let timers = [];
  const lane = [];
  const rootStyle = {
    setProperty: (name, value) => name === "--toast-lane" && lane.push(value),
    removeProperty: (name) => name === "--toast-lane" && lane.push(null)
  };

  const container = {
    children: [],
    appendChild(el) {
      el.parent = this;
      this.children.push(el);
    },
    getBoundingClientRect() {
      const n = this.children.length;
      const top = view.bottom - (n === 0 ? 0 : n * height + (n - 1) * view.gap);
      return {top, bottom: view.bottom, height: view.bottom - top};
    }
  };

  const context = {
    Date,
    window: {innerHeight: view.height, matchMedia: () => ({matches: phone})},
    document: {
      documentElement: {style: rootStyle},
      getElementById: (id) => (id === "toast-container" ? container : null),
      createElement: () => {
        const classes = new Set();
        return {
          className: "",
          textContent: "",
          classList: {add: (c) => classes.add(c), remove: (c) => classes.delete(c)},
          exiting: () => classes.has("toast-exit"),
          remove() {
            this.parent.children = this.parent.children.filter((el) => el !== this);
          }
        };
      }
    },
    requestAnimationFrame: (fn) => fn(),
    setTimeout: (fn, ms) => {
      timers.push({at: now + ms, fn});
      return timers.length;
    }
  };

  const toast = vm.runInNewContext(`${source.slice(start, end)}\nToast`, context);
  toast._queue = [];
  toast._activeToasts = [];
  toast._rateLimitMap = {};

  return {
    toast,
    lane,
    view,
    shown: () => container.children.map((el) => el.textContent),
    advance(ms) {
      const until = now + ms;
      for (;;) {
        const due = timers.filter((t) => t.at <= until).sort((a, b) => a.at - b.at)[0];
        if (!due) break;
        timers = timers.filter((t) => t !== due);
        now = due.at;
        due.fn();
      }
      now = until;
    }
  };
}

test("on a phone toasts take turns: an error, then a background success, each shown in full", () => {
  const p = page();
  p.toast._enqueue("Could not send this answer.", "error");
  p.toast._enqueue("Agent completed a run", "success");

  assert.deepEqual(p.shown(), ["Could not send this answer."], "only the first is on screen");

  p.advance(4999);
  assert.deepEqual(p.shown(), ["Could not send this answer."], "the error stays its full time");

  p.advance(1 + 300);
  assert.deepEqual(p.shown(), ["Agent completed a run"], "the success follows once it has gone");

  p.advance(4999);
  assert.deepEqual(p.shown(), ["Agent completed a run"], "and gets its own full time");

  p.advance(1 + 300);
  assert.deepEqual(p.shown(), []);
});

test("on wider screens up to five toasts show at once", () => {
  const p = page({phone: false});
  for (const n of [1, 2, 3, 4, 5, 6]) p.toast._enqueue(`Toast ${n}`, "info");

  assert.equal(p.shown().length, 5);
  p.advance(5300);
  assert.deepEqual(p.shown(), ["Toast 6"]);
});

test("while a toast shows, the page gets a lane above it, and the room back after", () => {
  for (const phone of [true, false]) {
    const p = page({phone});
    p.toast._enqueue("Answer sent.", "success");

    const top = p.view.bottom - p.view.toast;
    assert.deepEqual(p.lane, [`${p.view.height - top + p.view.gap}px`]);

    p.advance(5300);
    assert.deepEqual(p.lane.at(-1), null, "the lane goes with the last toast");
  }
});

test("the lane fits the toast that shows: a wrapped one, or a desktop stack", () => {
  const wrapped = page({toastHeight: 56});
  wrapped.toast._enqueue("Issue is not waiting on owner verification", "error");
  assert.deepEqual(wrapped.lane, [`${844 - (766 - 56) + 8}px`]);

  const stack = page({phone: false});
  stack.toast._enqueue("Answer sent.", "success");
  stack.toast._enqueue("Could not send this answer.", "error");
  assert.deepEqual(stack.lane.at(-1), `${900 - (884 - 2 * 40 - 8) + 8}px`);
});

test("a queued toast keeps the lane: the page does not jump between two toasts", () => {
  const p = page();
  p.toast._enqueue("Could not send this answer.", "error");
  p.toast._enqueue("Agent completed a run", "success");

  p.advance(5300);
  assert.deepEqual(p.shown(), ["Agent completed a run"]);
  assert.ok(!p.lane.includes(null), "the lane was never dropped");

  p.advance(5300);
  assert.equal(p.lane.at(-1), null);
});
