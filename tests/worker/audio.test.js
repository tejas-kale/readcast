import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../../worker/audio.js";

const bytes = new Uint8Array([0, 1, 2, 3, 4, 5]);
const calls = [];
const metadata = {
  size: bytes.length,
  httpEtag: '"etag"',
  writeHttpMetadata(headers) { headers.set("Content-Type", "audio/mpeg"); },
};
const bucket = {
  async head(key) { calls.push(["head", key]); return metadata; },
  async get(key, options) {
    calls.push(["get", key, options]);
    const start = options?.range.offset ?? 0;
    const end = start + (options?.range.length ?? bytes.length);
    return { body: new Response(bytes.slice(start, end)).body };
  },
};
const fetch = (method = "GET", range) => worker.fetch(new Request("https://audio.example/audio/test.mp3", { method, headers: range ? { Range: range } : {} }), { AUDIO_BUCKET: bucket });

test("GET streams complete audio with media and range headers", async () => {
  const response = await fetch();
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "audio/mpeg");
  assert.equal(response.headers.get("Accept-Ranges"), "bytes");
  assert.equal(response.headers.get("Content-Length"), "6");
  assert.deepEqual([...new Uint8Array(await response.arrayBuffer())], [...bytes]);
});

test("HEAD returns metadata without reading the body", async () => {
  const before = calls.length;
  const response = await fetch("HEAD");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Length"), "6");
  assert.equal(response.body, null);
  assert.equal(calls.length, before + 1);
});

test("valid and suffix ranges stream only requested bytes", async () => {
  const response = await fetch("GET", "bytes=2-4");
  assert.equal(response.status, 206);
  assert.equal(response.headers.get("Content-Range"), "bytes 2-4/6");
  assert.deepEqual([...new Uint8Array(await response.arrayBuffer())], [2, 3, 4]);
  assert.deepEqual(calls.at(-1)[2], { range: { offset: 2, length: 3 } });

  const suffix = await fetch("GET", "bytes=-2");
  assert.equal(suffix.status, 206);
  assert.deepEqual([...new Uint8Array(await suffix.arrayBuffer())], [4, 5]);
});

test("unsatisfiable range returns 416 with the complete size", async () => {
  const response = await fetch("GET", "bytes=99-");
  assert.equal(response.status, 416);
  assert.equal(response.headers.get("Content-Range"), "bytes */6");
  assert.equal(response.body, null);
});

test("unsupported methods and missing objects have HTTP errors", async () => {
  assert.equal((await fetch("POST")).status, 405);
  const missing = await worker.fetch(new Request("https://audio.example/missing.mp3"), { AUDIO_BUCKET: { head: async () => null } });
  assert.equal(missing.status, 404);
});

test("R2 failures return structured retryable errors", async () => {
  const failed = await worker.fetch(new Request("https://audio.example/audio/test.mp3"), {
    AUDIO_BUCKET: { head: async () => { throw new Error("storage timeout"); } },
  });
  assert.equal(failed.status, 503);
  assert.equal(failed.headers.get("Retry-After"), "60");
  assert.match(failed.headers.get("Content-Type"), /^application\/json/);
  assert.deepEqual(await failed.json(), { error: "Audio storage is temporarily unavailable", retryable: true });
});
