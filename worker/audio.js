function parseByteRange(value, size) {
  if (!value || !value.startsWith("bytes=") || value.includes(",")) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(value.trim());
  if (!match || (!match[1] && !match[2])) return null;
  if (!Number.isSafeInteger(size) || size < 0) return { unsatisfiable: true };
  let start;
  let end;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0 || size === 0) return { unsatisfiable: true };
    start = Math.max(size - suffix, 0);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] ? Number(match[2]) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || start > end) return { unsatisfiable: true };
    end = Math.min(end, size - 1);
  }
  return { start, end, length: end - start + 1 };
}

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    const pathname = new URL(request.url).pathname;
    const key = pathname.replace(/^\/+/, "");
    if (!key || key.includes("..") || key.includes("\\")) return new Response("Not found", { status: 404 });
    try {
      const metadata = await env.AUDIO_BUCKET.head(key);
      if (!metadata) return new Response("Not found", { status: 404 });
      const headers = new Headers();
      metadata.writeHttpMetadata(headers);
      headers.set("Content-Type", "audio/mpeg");
      headers.set("Accept-Ranges", "bytes");
      headers.set("Content-Length", String(metadata.size));
      headers.set("ETag", metadata.httpEtag);
      headers.set("Cache-Control", "public, max-age=31536000, immutable");
      if (request.method === "HEAD") return new Response(null, { status: 200, headers });

      const rangeHeader = request.headers.get("Range");
      const range = parseByteRange(rangeHeader, metadata.size);
      if (range?.unsatisfiable) {
        headers.set("Content-Range", `bytes */${metadata.size}`);
        return new Response(null, { status: 416, headers });
      }
      const object = range
        ? await env.AUDIO_BUCKET.get(key, { range: { offset: range.start, length: range.length } })
        : await env.AUDIO_BUCKET.get(key);
      if (!object || !object.body) return new Response("Audio object unavailable", { status: 502 });
      if (range) {
        headers.set("Content-Range", `bytes ${range.start}-${range.end}/${metadata.size}`);
        headers.set("Content-Length", String(range.length));
        return new Response(object.body, { status: 206, headers });
      }
      return new Response(object.body, { status: 200, headers });
    } catch (error) {
      console.error(JSON.stringify({ message: "R2 audio read failed", key, error: error instanceof Error ? error.message : String(error) }));
      return Response.json(
        { error: "Audio storage is temporarily unavailable", retryable: true },
        { status: 503, headers: { "Retry-After": "60" } },
      );
    }
  },
};
