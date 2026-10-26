import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

// The colour picker (projects) marks the chosen swatch with aria-pressed, which r3 CSS rings
// with tokens. It used to write white borders inline, which vanished on the light paper card.
const source = await readFile(new URL("../../assets/js/app.js", import.meta.url), "utf8");
const start = source.indexOf("const ColorSwatchPicker = {");
const end = source.indexOf("\n};\n", start) + 4;
assert.ok(start >= 0 && end > start, "the ColorSwatchPicker hook is present");

function swatch(hex) {
  const attrs = {};
  const listeners = {};
  return {
    dataset: {hex},
    style: {},
    attrs,
    setAttribute: (name, value) => (attrs[name] = String(value)),
    addEventListener: (type, fn) => (listeners[type] = fn),
    click() {
      listeners.click({currentTarget: this});
    }
  };
}

function picker(value) {
  const swatches = [swatch("#D97757"), swatch("#5db8a6")];
  const input = {
    value,
    listeners: {},
    addEventListener(type, fn) {
      this.listeners[type] = fn;
    },
    dispatchEvent(event) {
      this.listeners[event.type] && this.listeners[event.type](event);
    }
  };
  const preview = {style: {}};
  const el = {
    querySelector: (sel) => (sel === "[data-hex-input]" ? input : preview),
    querySelectorAll: () => swatches
  };
  const Hook = vm.runInNewContext(`${source.slice(start, end)}\nColorSwatchPicker`, {
    Event: class {
      constructor(type) {
        this.type = type;
      }
    }
  });
  const hook = Object.assign(Object.create(Hook), {el});
  hook.mounted();
  return {hook, swatches, input, preview};
}

test("the swatch matching the value is pressed, the others are not, and no colour is written inline", () => {
  const {swatches} = picker("#5DB8A6");

  assert.equal(swatches[0].attrs["aria-pressed"], "false");
  assert.equal(swatches[1].attrs["aria-pressed"], "true");
  assert.equal(swatches[0].style.borderColor, undefined);
  assert.equal(swatches[1].style.borderColor, undefined);
});

test("clicking a swatch copies its hex into the field and presses it", () => {
  const {swatches, input} = picker("");

  swatches[0].click();

  assert.equal(input.value, "#D97757");
  assert.equal(swatches[0].attrs["aria-pressed"], "true");
  assert.equal(swatches[1].attrs["aria-pressed"], "false");
});

test("after a LiveView patch the pressed state follows the field again", () => {
  const {hook, swatches, input} = picker("#D97757");

  input.value = "#5db8a6";
  hook.updated();

  assert.equal(swatches[0].attrs["aria-pressed"], "false");
  assert.equal(swatches[1].attrs["aria-pressed"], "true");
});
