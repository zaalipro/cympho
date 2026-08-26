import assert from "node:assert/strict";
import {createHash, webcrypto} from "node:crypto";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(new URL("../../assets/js/app.js", import.meta.url), "utf8");
const start = source.indexOf("const COMPANY_IMPORT_PART_BYTES");
const end = source.indexOf("// Boot", start);
assert.ok(start >= 0 && end > start, "company import hook source is present");

const context = {
  AbortController,
  DOMException,
  Response,
  Set,
  Uint8Array,
  Uint32Array,
  DataView,
  Math,
  Promise,
  Error,
  JSON,
  String,
  Array,
  document: {
    querySelector() {
      return {getAttribute: () => "csrf-token-for-test"};
    }
  },
  window: {
    crypto: webcrypto,
    setTimeout,
    clearTimeout
  }
};
context.globalThis = context;
vm.runInNewContext(
  `${source.slice(start, end)}\nglobalThis.__companyImportTest = {IncrementalSha256, CompanyImportTransfer};`,
  context
);
const {IncrementalSha256, CompanyImportTransfer} = context.__companyImportTest;

test("incremental SHA-256 matches standard vectors across uneven updates", () => {
  const hash = new IncrementalSha256();
  hash.update(new TextEncoder().encode("a"));
  hash.update(new TextEncoder().encode("bc"));
  assert.equal(
    hash.hexDigest(),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  );
});

test("file selection clears the native control so the same file can be selected again", () => {
  let changeHandler;
  let startedFile;
  const file = new File(["{}"], "portable.json", {type: "application/json"});
  const element = {
    dataset: {},
    addEventListener(name, handler) {
      if (name === "change") changeHandler = handler;
    },
    removeEventListener() {}
  };
  const hook = Object.assign({}, CompanyImportTransfer, {
    el: element,
    handleEvent() {},
    start(selected) { startedFile = selected; }
  });

  hook.mounted();
  const input = {
    files: [file],
    value: "/fake/path/portable.json",
    matches: (selector) => selector === "[data-transfer-file]"
  };
  changeHandler({target: input});

  assert.equal(startedFile, file);
  assert.equal(input.value, "");
});

test("transfer hook declares stable content, uploads only missing bounded parts, and previews", async () => {
  const bytes = new Uint8Array(4 * 1024 * 1024 + 17);
  for (let index = 0; index < bytes.length; index += 1) bytes[index] = index % 251;
  const file = new File([bytes], "portable.json", {type: "application/json"});
  const calls = [];
  const events = [];
  const transferId = "8d08b345-cd28-4399-a36f-6bb4e5fd7781";

  context.fetch = async (url, options) => {
    calls.push({url, options});
    if (url.endsWith("/transfers")) {
      return Response.json({
        transfer_id: transferId,
        uploaded_parts: 1,
        missing_parts: [1]
      }, {status: 201});
    }
    if (url.endsWith("/parts/1")) return Response.json({ok: true});
    if (url.endsWith("/preview")) {
      return Response.json({data: {ready: true, company: {name: "Portable"}}});
    }
    throw new Error(`unexpected URL ${url}`);
  };

  const element = {
    dataset: {basePath: "/companies/import/transfers"},
    querySelector: () => null
  };
  const hook = Object.assign({}, CompanyImportTransfer, {
    el: element,
    cancelled: false,
    requestController: new AbortController(),
    pushEvent(name, payload) { events.push({name, payload}); },
    showProgress() {}
  });

  await hook.start(file);

  const declaration = JSON.parse(calls[0].options.body);
  assert.equal(declaration.parts.length, 2);
  assert.ok(declaration.parts.every((part) => part.byte_size <= 4 * 1024 * 1024));
  assert.equal(declaration.file_sha256, createHash("sha256").update(bytes).digest("hex"));
  assert.equal(declaration.idempotency_key, `cympho_${declaration.file_sha256}_suffix`);
  assert.deepEqual(declaration.import_options, {slug_strategy: "suffix"});
  assert.deepEqual(
    calls.filter((call) => call.url.includes("/parts/")).map((call) => call.url),
    [`/companies/import/transfers/${transferId}/parts/1`]
  );
  assert.equal(calls[1].options.body.byteLength, 17);
  assert.equal(calls[1].options.headers["content-type"], "application/octet-stream");
  assert.equal(calls[1].options.headers["x-csrf-token"], "csrf-token-for-test");
  assert.deepEqual(events.map((event) => event.name), ["transfer_declared", "transfer_previewed"]);
  assert.equal(events[0].payload.slug_strategy, "suffix");
});

test("completed declaration reports the existing company without previewing or uploading", async () => {
  const transferId = "8d08b345-cd28-4399-a36f-6bb4e5fd7781";
  const companyId = "ff725928-3d75-4cf2-bf10-879bb65341af";
  const calls = [];
  const events = [];
  context.fetch = async (url, options) => {
    calls.push({url, options});
    return Response.json({
      transfer_id: transferId,
      already_completed: true,
      imported_company_id: companyId,
      secrets_to_restore: [{name: "PROVIDER_TOKEN", kind: "secret"}],
      restore_receipt_available: true,
      uploaded_parts: 1,
      missing_parts: []
    });
  };

  const hook = Object.assign({}, CompanyImportTransfer, {
    el: {dataset: {basePath: "/companies/import/transfers"}, querySelector: () => null},
    cancelled: false,
    requestController: new AbortController(),
    pushEvent(name, payload) { events.push({name, payload}); },
    showProgress() {}
  });

  await hook.start(new File(["{}"], "completed.json", {type: "application/json"}));

  assert.equal(calls.length, 1);
  assert.deepEqual(events.map((event) => event.name), ["transfer_declared", "transfer_completed"]);
  assert.equal(events[1].payload.imported_company_id, companyId);
  assert.deepEqual(events[1].payload.secrets_to_restore, [
    {name: "PROVIDER_TOKEN", kind: "secret"}
  ]);
  assert.equal(events[1].payload.restore_receipt_available, true);
});

test("chosen collision strategy is immutable transfer manifest identity", async () => {
  let declaration;
  context.fetch = async (url, options) => {
    if (url.endsWith("/transfers")) {
      declaration = JSON.parse(options.body);
      return Response.json({
        transfer_id: "c3179191-3fc0-422e-9354-c879dbcf204f",
        already_completed: true,
        imported_company_id: "2a9162d1-67de-442e-8247-e1c31376c907",
        missing_parts: []
      });
    }
    throw new Error(`unexpected URL ${url}`);
  };

  const hook = Object.assign({}, CompanyImportTransfer, {
    el: {
      dataset: {basePath: "/companies/import/transfers"},
      querySelector(selector) {
        return selector.includes("data-transfer-strategy") ? {value: "fail"} : null;
      }
    },
    cancelled: false,
    requestController: new AbortController(),
    pushEvent() {},
    showProgress() {}
  });

  await hook.start(new File(["{}"], "fail-policy.json", {type: "application/json"}));

  assert.deepEqual(declaration.import_options, {slug_strategy: "fail"});
  assert.ok(declaration.idempotency_key.endsWith("_fail"));
});

test("pause aborts locally without deleting resumable server state", async () => {
  let fetchCount = 0;
  const events = [];
  context.fetch = async () => {
    fetchCount += 1;
    return new Response(null, {status: 204});
  };
  const hook = Object.assign({}, CompanyImportTransfer, {
    el: {querySelector: () => null},
    transferId: "3c33183d-19e1-42df-9437-596a0cb278e7",
    cancelled: false,
    requestController: new AbortController(),
    pushEvent(name) { events.push(name); },
    resetProgress() {}
  });
  const controller = hook.requestController;

  await hook.cancel();

  assert.equal(fetchCount, 0);
  assert.equal(controller.signal.aborted, true);
  assert.equal(hook.workflowGeneration, 1);
  assert.equal(hook.transferId, null);
  assert.deepEqual(events, ["transfer_cancelled"]);
});

test("overlapping file selections cannot let the old workflow use the new transfer", async () => {
  const oldTransferId = "dfe1dbdf-195c-4eb6-9c31-c114686362ff";
  const newTransferId = "707508f3-c5ad-40a7-a6ac-eb36401f64c1";
  const oldBytes = new TextEncoder().encode("old");
  let releaseOldUploadRead;
  let oldUploadReadStarted;
  const oldUploadRead = new Promise((resolve) => { oldUploadReadStarted = resolve; });
  const oldUploadBytes = new Promise((resolve) => { releaseOldUploadRead = resolve; });
  let oldReadCount = 0;
  const oldFile = {
    name: "old.json",
    size: oldBytes.byteLength,
    slice() {
      oldReadCount += 1;
      if (oldReadCount === 1) return {arrayBuffer: async () => oldBytes.buffer};
      oldUploadReadStarted();
      return {arrayBuffer: () => oldUploadBytes};
    }
  };
  const calls = [];
  const events = [];

  context.fetch = async (url, options) => {
    calls.push({url, options});
    if (url.endsWith("/transfers")) {
      const declaration = JSON.parse(options.body);
      const oldHash = createHash("sha256").update(oldBytes).digest("hex");
      const isOld = declaration.file_sha256 === oldHash;
      return Response.json({
        transfer_id: isOld ? oldTransferId : newTransferId,
        uploaded_parts: 0,
        missing_parts: isOld ? [0] : []
      }, {status: 201});
    }
    if (url.endsWith(`/${newTransferId}/preview`)) {
      return Response.json({data: {ready: true}});
    }
    throw new Error(`superseded workflow made unexpected request ${url}`);
  };

  const hook = Object.assign({}, CompanyImportTransfer, {
    el: {
      dataset: {basePath: "/companies/import/transfers"},
      querySelector: () => null
    },
    cancelled: false,
    requestController: null,
    workflowGeneration: 0,
    pushEvent(name, payload) { events.push({name, payload}); },
    showProgress() {}
  });

  const oldStart = hook.start(oldFile);
  await oldUploadRead;
  await hook.start(new File(["new"], "new.json", {type: "application/json"}));
  assert.equal(hook.transferId, newTransferId);

  releaseOldUploadRead(oldBytes.buffer);
  await oldStart;

  assert.deepEqual(
    calls.map(({url}) => url),
    [
      "/companies/import/transfers",
      "/companies/import/transfers",
      `/companies/import/transfers/${newTransferId}/preview`
    ]
  );
  assert.deepEqual(
    events.filter(({name}) => name === "transfer_previewed").map(({payload}) => payload.transfer_id),
    [newTransferId]
  );
  assert.deepEqual(
    events.filter(({name}) => name === "transfer_declared").map(({payload}) => payload.transfer_id),
    [oldTransferId, newTransferId]
  );
  assert.equal(hook.transferId, newTransferId);
});

test("non-JSON transfer failures never echo the response body", async () => {
  const hook = Object.assign({}, CompanyImportTransfer);
  const payload = await hook.responsePayload(new Response("private proxy details", {
    status: 502,
    headers: {"content-type": "text/html"}
  }));

  assert.equal(payload.error, "Transfer request failed (502).");
  assert.equal(Object.keys(payload).length, 1);
});
