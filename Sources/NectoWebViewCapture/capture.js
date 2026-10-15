//
//  Copyright (c) 2026 Viva Republica, Inc.
//
// Injected by NectoWebViewCapture into every frame at document start, in the page's own
// content world, because it has to wrap the page's own `fetch` and `XMLHttpRequest`.
// Each request is posted to the `nectoWebViewCapture` handler twice under one id:
// `pending` when it starts, then `completed` or `failed`. The page sees nothing change:
// it receives the same responses, the same rejections and the same exceptions.

(() => {
  "use strict";

  if (window.__nectoWebViewCapture) return;
  Object.defineProperty(window, "__nectoWebViewCapture", { value: true });

  // Taken now, so a page that later replaces globals cannot cut the channel.
  const receiver = window.webkit?.messageHandlers?.nectoWebViewCapture;
  if (!receiver) return;
  const postMessage = receiver.postMessage.bind(receiver);

  const NativeRequest = window.Request;
  const NativeURL = window.URL;
  const NativeHeaders = window.Headers;
  const now = Date.now.bind(Date);
  const clock = performance.now.bind(performance);
  const randomUUID = typeof crypto?.randomUUID === "function" ? crypto.randomUUID.bind(crypto) : undefined;
  const encoder = new TextEncoder();

  // NectoNetworkRecord.Body.captureLimit.
  const captureLimit = 512 * 1024;

  let sequence = 0;

  // `randomUUID` exists only in a secure context, and a page served over plain HTTP
  // is not one.
  function newID() {
    if (randomUUID) return randomUUID();
    sequence += 1;
    return `webview-${now()}-${sequence}-${Math.random().toString(36).slice(2)}`;
  }

  function post(record) {
    try {
      postMessage({ kind: "network", record });
    } catch {
      // Capture never breaks the page.
    }
  }

  // The same rule as NectoNetworkRecord.Body.looksTextual in NectoDefaultPlugins.
  // Change both together.
  function looksTextual(contentType) {
    if (!contentType) return true;
    const type = contentType.toLowerCase();
    return ["json", "text", "xml", "javascript", "x-www-form-urlencoded"].some((part) => type.includes(part));
  }

  // Bytes become text only when they decode cleanly, as in Swift. A character cut in
  // half by the cap is held back rather than counted as invalid.
  function decode(bytes, contentType) {
    const charset = /charset=["']?([^;"'\s]+)/i.exec(contentType ?? "")?.[1];
    let decoder;
    try {
      decoder = new TextDecoder(charset ?? "utf-8", { fatal: true });
    } catch {
      decoder = new TextDecoder("utf-8", { fatal: true });
    }
    try {
      return decoder.decode(bytes, { stream: true });
    } catch {
      return undefined;
    }
  }

  function bytesBody(bytes, byteCount, contentType) {
    const body = { byteCount, isTruncated: byteCount > captureLimit };
    if (contentType) body.contentType = contentType;
    if (looksTextual(contentType)) {
      const text = decode(bytes.subarray(0, captureLimit), contentType);
      if (text !== undefined) body.text = text;
    }
    return body;
  }

  function textBody(text, contentType) {
    const bytes = encoder.encode(text);
    if (bytes.byteLength <= captureLimit) {
      const body = { byteCount: bytes.byteLength, isTruncated: false };
      if (contentType) body.contentType = contentType;
      if (looksTextual(contentType)) body.text = text;
      return body;
    }
    return bytesBody(bytes, bytes.byteLength, contentType);
  }

  function sizeBody(byteCount, contentType) {
    const body = { byteCount, isTruncated: false };
    if (contentType) body.contentType = contentType;
    return body;
  }

  // What the page asked to send. Text is kept; anything that would have to be read
  // asynchronously, or that is binary, is recorded by size; a stream is not read.
  function requestBody(body, contentType) {
    if (body === undefined || body === null) return undefined;
    if (typeof body === "string") return textBody(body, contentType ?? "text/plain;charset=UTF-8");
    if (body instanceof URLSearchParams) {
      return textBody(body.toString(), contentType ?? "application/x-www-form-urlencoded;charset=UTF-8");
    }
    if (body instanceof Blob) return sizeBody(body.size, contentType ?? (body.type || undefined));
    if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) return sizeBody(body.byteLength, contentType);
    if (body instanceof FormData) {
      // The fields' own sizes. The encoded form adds a boundary and part headers.
      let size = 0;
      for (const [, value] of body) size += typeof value === "string" ? encoder.encode(value).byteLength : value.size;
      return sizeBody(size, contentType ?? "multipart/form-data");
    }
    return undefined;
  }

  function headerObject(source) {
    const headers = {};
    if (source === undefined || source === null) return headers;
    try {
      new NativeHeaders(source).forEach((value, name) => {
        headers[name] = value;
      });
    } catch {
      // Headers the page could not send either.
    }
    return headers;
  }

  // As fetch and XMLHttpRequest do: the standard methods are uppercased, any other
  // method is sent exactly as written.
  function normalizeMethod(method) {
    const upper = String(method).toUpperCase();
    return ["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"].includes(upper) ? upper : String(method);
  }

  function describeError(error) {
    if (error && typeof error === "object" && "message" in error) {
      return error.name ? `${error.name}: ${error.message}` : String(error.message);
    }
    return String(error);
  }

  function finished(record, started, fields) {
    post({ ...record, durationMilliseconds: clock() - started, ...fields });
  }

  // -- fetch -------------------------------------------------------------------------

  // Reads a stream to its end but keeps only the first `captureLimit` bytes, so a large
  // download costs its size in time, not in memory.
  async function readCapped(stream) {
    const reader = stream.getReader();
    const chunks = [];
    let keptCount = 0;
    let byteCount = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      byteCount += value.byteLength;
      if (keptCount < captureLimit) {
        const chunk = value.subarray(0, captureLimit - keptCount);
        chunks.push(chunk);
        keptCount += chunk.byteLength;
      }
    }
    const bytes = new Uint8Array(keptCount);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return { byteCount, bytes };
  }

  function observeResponse(record, started, response) {
    const contentType = response.headers.get("content-type") ?? undefined;
    const answered = { state: "completed", statusCode: response.status, responseHeaders: headerObject(response.headers) };

    // An event stream may never end, and reading a copy of it would leave the row
    // pending forever while the copy buffered every event.
    if (!response.body || /text\/event-stream/i.test(contentType ?? "")) {
      finished(record, started, answered);
      return;
    }

    readCapped(response.clone().body).then(
      ({ byteCount, bytes }) => {
        const body = byteCount > 0 ? { responseBody: bytesBody(bytes, byteCount, contentType) } : {};
        finished(record, started, { ...answered, responseByteCount: byteCount, ...body });
      },
      (error) => {
        finished(record, started, { ...answered, state: "failed", errorSummary: describeError(error) });
      },
    );
  }

  const nativeFetch = window.fetch;
  if (typeof nativeFetch === "function") {
    // One declared parameter, like the browser's own.
    window.fetch = function fetch(input) {
      const init = arguments[1];
      let record;
      try {
        // A Request's body is a stream, so it is not read; a body in `init` replaces it.
        const request = input instanceof NativeRequest ? input : undefined;
        const requestHeaders = headerObject(init?.headers ?? request?.headers);
        const body = init && "body" in init ? init.body : undefined;
        record = {
          id: newID(),
          method: normalizeMethod(init?.method ?? request?.method ?? "GET"),
          url: new NativeURL(request ? request.url : String(input), document.baseURI).href,
          startedAtMilliseconds: now(),
          requestHeaders,
        };
        post({ ...record, state: "pending" });
        const captured = requestBody(body, requestHeaders["content-type"]);
        if (captured) record.requestBody = captured;
      } catch {
        record = undefined;
      }

      const started = clock();
      const promise = nativeFetch.apply(this, arguments);
      if (!record) return promise;

      return promise.then(
        (response) => {
          try {
            observeResponse(record, started, response);
          } catch {
            // Capture never breaks the page.
          }
          return response;
        },
        (error) => {
          finished(record, started, { state: "failed", errorSummary: describeError(error) });
          throw error;
        },
      );
    };
  }

  // -- XMLHttpRequest ----------------------------------------------------------------

  const NativeXHR = window.XMLHttpRequest;
  if (typeof NativeXHR === "function") {
    const prototype = NativeXHR.prototype;
    const nativeOpen = prototype.open;
    const nativeSetRequestHeader = prototype.setRequestHeader;
    const nativeSend = prototype.send;
    const opened = new WeakMap();

    function parseHeaders(text) {
      const headers = {};
      for (const line of (text ?? "").split(/\r?\n/)) {
        const colon = line.indexOf(":");
        if (colon > 0) headers[line.slice(0, colon).trim().toLowerCase()] = line.slice(colon + 1).trim();
      }
      return headers;
    }

    function responseBody(request, contentType) {
      switch (request.responseType) {
        case "":
        case "text":
          return textBody(request.responseText, contentType);
        case "json":
          return request.response === null ? undefined : textBody(JSON.stringify(request.response), contentType);
        case "arraybuffer":
          return request.response
            ? bytesBody(new Uint8Array(request.response), request.response.byteLength, contentType)
            : undefined;
        case "blob":
          return request.response ? sizeBody(request.response.size, contentType) : undefined;
        case "document":
          return request.responseXML?.documentElement
            ? textBody(request.responseXML.documentElement.outerHTML, contentType)
            : undefined;
        default:
          return undefined;
      }
    }

    const failures = {
      timeout: "The request timed out.",
      abort: "The request was aborted.",
      error: "The request failed.",
    };

    function finish(request, record, started, failure) {
      // Status 0 means no response arrived at all.
      if (request.status === 0) {
        finished(record, started, { state: "failed", errorSummary: failures[failure] ?? failures.error });
        return;
      }
      const contentType = request.getResponseHeader("content-type") ?? undefined;
      const body = responseBody(request, contentType);
      const fields = {
        state: "completed",
        statusCode: request.status,
        responseHeaders: parseHeaders(request.getAllResponseHeaders()),
      };
      if (body) fields.responseByteCount = body.byteCount;
      if (body && body.byteCount > 0) fields.responseBody = body;
      finished(record, started, fields);
    }

    prototype.open = function open(method, url) {
      const result = nativeOpen.apply(this, arguments);
      try {
        opened.set(this, {
          method: normalizeMethod(method),
          url: new NativeURL(String(url), document.baseURI).href,
          requestHeaders: {},
        });
      } catch {
        opened.delete(this);
      }
      return result;
    };

    prototype.setRequestHeader = function setRequestHeader(name, value) {
      const result = nativeSetRequestHeader.apply(this, arguments);
      const state = opened.get(this);
      if (state) {
        // Repeated headers combine, as the browser sends them.
        const key = String(name).toLowerCase();
        const headers = state.requestHeaders;
        headers[key] = key in headers ? `${headers[key]}, ${value}` : String(value);
      }
      return result;
    };

    prototype.send = function send() {
      const state = opened.get(this);
      if (!state) return nativeSend.apply(this, arguments);

      const record = {
        id: newID(),
        method: state.method,
        url: state.url,
        startedAtMilliseconds: now(),
        requestHeaders: { ...state.requestHeaders },
      };
      const events = ["error", "abort", "timeout", "loadend"];
      let started;
      let failure;
      const listen = (event) => {
        if (event.type !== "loadend") {
          failure = event.type;
          return;
        }
        for (const type of events) this.removeEventListener(type, listen);
        finish(this, record, started, failure);
      };
      try {
        post({ ...record, state: "pending" });
        const captured = requestBody(arguments[0], state.requestHeaders["content-type"]);
        if (captured) record.requestBody = captured;
        for (const type of events) this.addEventListener(type, listen);
      } catch {
        // Capture never breaks the page.
      }

      started = clock();
      try {
        return nativeSend.apply(this, arguments);
      } catch (error) {
        // `send` refused to start, or a synchronous request failed: either way no
        // `loadend` follows, so the record ends here.
        for (const type of events) this.removeEventListener(type, listen);
        finished(record, started, { state: "failed", errorSummary: describeError(error) });
        throw error;
      }
    };
  }
})();
