// Run with: node --test test/js/own_answer_focus_test.mjs
//
// The Next step's "Or write your own answer" row (CymphoWeb.Components.R3.option_rows)
// reveals its text box with CSS only; choosing the row must also move the caret
// into it, or what the owner types goes to the radio and is lost (smoke B9).
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(new URL("../../assets/js/app.js", import.meta.url), "utf8");
const start = source.indexOf("function focusOwnAnswer(");
const endMarker = "document.addEventListener('click', focusOwnAnswer);";
const end = source.indexOf(endMarker, start);
assert.ok(start >= 0 && end > start, "the own-answer focus listener is in app.js");

const listeners = {};
const context = {
  document: {
    addEventListener(name, handler) {
      (listeners[name] ||= []).push(handler);
    }
  }
};
vm.runInNewContext(source.slice(start, end + endMarker.length), context);

const fire = (name, target) => (listeners[name] || []).forEach((handler) => handler({target}));

// One .opt-w row: its radio, and for the own row the .own-box text box after it.
function row({own, checked}) {
  const textarea = {focused: 0, focus() { this.focused += 1; }};
  const wrapper = {querySelector: (selector) => (own && selector === ".own-box textarea" ? textarea : null)};
  const radio = {
    checked,
    classList: {contains: (name) => name === "opt-in"},
    closest: (selector) => (selector === ".opt-w" ? wrapper : null)
  };
  return {radio, textarea};
}

test("listens on the document, so every page's own row is covered without a hook", () => {
  assert.equal(listeners.change?.length, 1);
  assert.equal(listeners.click?.length, 1);
});

test("choosing the own row by keyboard or mouse (change) moves the caret into its text box", () => {
  const {radio, textarea} = row({own: true, checked: true});
  fire("change", radio);
  assert.equal(textarea.focused, 1);
});

test("clicking the own row again when it is already chosen (no change) still moves the caret", () => {
  const {radio, textarea} = row({own: true, checked: true});
  fire("click", radio);
  assert.equal(textarea.focused, 1);
});

test("a numbered option keeps the focus on its radio", () => {
  const own = row({own: true, checked: false});
  const numbered = row({own: false, checked: true});
  fire("change", numbered.radio);
  fire("click", numbered.radio);
  assert.equal(own.textarea.focused, 0);
});

test("other clicks and changes are ignored", () => {
  assert.doesNotThrow(() => {
    fire("click", {classList: {contains: () => false}});
    fire("change", {});
  });
});
