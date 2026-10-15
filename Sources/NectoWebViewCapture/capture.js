//
//  Copyright (c) 2026 Viva Republica, Inc.
//
// Injected by NectoWebViewCapture into every frame at document start, in the page's own
// content world, because it has to wrap the page's own `fetch` and `XMLHttpRequest`.
// Each request is posted to the `nectoWebViewCapture` handler twice under one id:
// `pending` when it starts, then `completed` or `failed`. The page sees nothing change:
// it receives the same responses, the same rejections and the same exceptions, and
// nothing capture does can throw into it.

(() => {
  "use strict";

  if (window.__nectoWebViewCapture) return;
  Object.defineProperty(window, "__nectoWebViewCapture", { value: true });

  const receiver = window.webkit?.messageHandlers?.nectoWebViewCapture;
  if (!receiver) return;

  // Taken now, so a page that later replaces globals neither cuts the channel nor
  // breaks a record half way.
  const postMessage = receiver.postMessage.bind(receiver);
  const NativeArrayBuffer = ArrayBuffer;
  const NativeBlob = Blob;
  const NativeFormData = FormData;
  const NativeHeaders = Headers;
  const NativeRequest = Request;
  const NativeTextDecoder = TextDecoder;
  const NativeURL = URL;
  const NativeURLSearchParams = URLSearchParams;
  const isView = ArrayBuffer.isView;
  const stringify = JSON.stringify;
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

  // Capture never throws into the page.
  function safely(work) {
    try {
      work();
    } catch {
      // The record is lost; the page is not.
    }
  }

  function post(record) {
    safely(() => postMessage({ kind: "network", record }));
  }

  // The same rule as NectoNetworkRecord.Body.looksTextual in NectoDefaultPlugins.
  // Change both together.
  function looksTextual(contentType) {
    if (!contentType) return true;
    const type = contentType.toLowerCase();
    return ["json", "text", "xml", "javascript", "x-www-form-urlencoded"].some((part) => type.includes(part));
  }

  function charsetOf(contentType) {
    return /charset=["']?([^;"'\s]+)/i.exec(contentType ?? "")?.[1] ?? "utf-8";
  }

  // Bytes become text only when they decode cleanly, as in Swift. Only when the cap cut
  // the body is a character left incomplete at the end held back instead.
  function decode(bytes, charset, isCut) {
    let decoder;
    try {
      decoder = new NativeTextDecoder(charset, { fatal: true });
    } catch {
      decoder = new NativeTextDecoder("utf-8", { fatal: true });
    }
    try {
      return decoder.decode(bytes, { stream: isCut });
    } catch {
      return undefined;
    }
  }

  function bytesBody(bytes, byteCount, contentType, charset) {
    const body = { byteCount, isTruncated: byteCount > captureLimit };
    if (contentType) body.contentType = contentType;
    if (looksTextual(contentType)) {
      const text = decode(bytes.subarray(0, captureLimit), charset, body.isTruncated);
      if (text !== undefined) body.text = text;
    }
    return body;
  }

  // Text the page already holds, decoded with whatever charset it came in. It is kept
  // as UTF-8, which also replaces a lone surrogate the receiver could not read.
  function textBody(text, contentType) {
    const bytes = encoder.encode(text);
    return bytesBody(bytes, bytes.byteLength, contentType, "utf-8");
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
    if (body instanceof NativeURLSearchParams) {
      return textBody(body.toString(), contentType ?? "application/x-www-form-urlencoded;charset=UTF-8");
    }
    if (body instanceof NativeBlob) return sizeBody(body.size, contentType ?? (body.type || undefined));
    if (body instanceof NativeArrayBuffer || isView(body)) return sizeBody(body.byteLength, contentType);
    if (body instanceof NativeFormData) {
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
      // A one-shot iterator, a generator for one, would be used up here and reach the
      // network empty, so it is left unread.
      const iterate = source[Symbol.iterator];
      if (typeof iterate === "function" && !(source instanceof NativeHeaders) && iterate.call(source) === source) {
        return headers;
      }
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
    try {
      if (error && typeof error === "object" && "message" in error) {
        return error.name ? `${error.name}: ${error.message}` : String(error.message);
      }
      return String(error);
    } catch {
      return Object.prototype.toString.call(error);
    }
  }

  function finished(record, started, fields) {
    post({ ...record, durationMilliseconds: clock() - started, ...fields });
  }

  // -- fetch -------------------------------------------------------------------------

  // Media types that last as long as the connection does. Reading a copy of one would
  // hold the row pending, and since the copy keeps the stream open, a page that
  // cancels its own reader would wait for it.
  const streaming =
    /^\s*(text\/event-stream|application\/(x-)?ndjson|application\/jsonl|application\/json-seq|application\/stream\+json|multipart\/x-mixed-replace)/i;

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

    let copy;
    try {
      if (response.body && !streaming.test(contentType ?? "")) copy = response.clone().body;
    } catch {
      copy = undefined;
    }
    if (!copy) {
      finished(record, started, answered);
      return;
    }

    readCapped(copy).then(
      ({ byteCount, bytes }) =>
        safely(() => {
          const body = byteCount > 0 ? { responseBody: bytesBody(bytes, byteCount, contentType, charsetOf(contentType)) } : {};
          finished(record, started, { ...answered, responseByteCount: byteCount, ...body });
        }),
      (error) =>
        safely(() => finished(record, started, { ...answered, state: "failed", errorSummary: describeError(error) })),
    );
  }

  // Everything is worked out before `pending` is posted, so a record either starts
  // and ends, or never appears.
  function describeFetch(input, init) {
    try {
      // A Request's body is a stream, so it is not read; a body in `init` replaces it.
      const request = input instanceof NativeRequest ? input : undefined;
      const requestHeaders = headerObject(init?.headers ?? request?.headers);
      const record = {
        id: newID(),
        method: normalizeMethod(init?.method ?? request?.method ?? "GET"),
        url: new NativeURL(request ? request.url : String(input), document.baseURI).href,
        startedAtMilliseconds: now(),
        requestHeaders,
      };
      const body = init && "body" in init ? requestBody(init.body, requestHeaders["content-type"]) : undefined;
      post({ ...record, state: "pending" });
      if (body) record.requestBody = body;
      return record;
    } catch {
      return undefined;
    }
  }

  const nativeFetch = window.fetch;
  if (typeof nativeFetch === "function") {
    // Method syntax, so the wrapper is no constructor, like the browser's own, and has
    // one declared parameter as it does.
    window.fetch = {
      fetch(input) {
        const record = describeFetch(input, arguments[1]);
        const started = clock();
        const promise = nativeFetch.apply(this, arguments);
        if (!record) return promise;

        return promise.then(
          (response) => {
            safely(() => observeResponse(record, started, response));
            return response;
          },
          (error) => {
            safely(() => finished(record, started, { state: "failed", errorSummary: describeError(error) }));
            throw error;
          },
        );
      },
    }.fetch;
  }

  // -- XMLHttpRequest ----------------------------------------------------------------

  const NativeXHR = window.XMLHttpRequest;
  if (typeof NativeXHR === "function") {
    const prototype = NativeXHR.prototype;
    const native = {
      open: prototype.open,
      setRequestHeader: prototype.setRequestHeader,
      send: prototype.send,
      abort: prototype.abort,
    };
    const opened = new WeakMap();
    const inFlight = new WeakMap();
    const events = ["load", "error", "abort", "timeout", "loadend"];
    const failures = {
      timeout: "The request timed out.",
      abort: "The request was aborted.",
      error: "The request failed.",
    };

    function parseHeaders(text) {
      const headers = {};
      for (const line of (text ?? "").split(/\r?\n/)) {
        const colon = line.indexOf(":");
        if (colon > 0) headers[line.slice(0, colon).trim().toLowerCase()] = line.slice(colon + 1).trim();
      }
      return headers;
    }

    // An XHR hands over its body already decoded, so its size is that of the text,
    // not of the bytes on the wire.
    function responseBody(request, contentType) {
      switch (request.responseType) {
        case "":
        case "text":
          return textBody(request.responseText, contentType);
        case "json":
          return request.response === null ? undefined : textBody(stringify(request.response), contentType);
        case "arraybuffer":
          return request.response
            ? bytesBody(new Uint8Array(request.response), request.response.byteLength, contentType, charsetOf(contentType))
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

    // Ends one request's record, once, from what the XHR holds right now.
    function settle(request, flight, failure, summary) {
      if (flight.done) return;
      flight.done = true;
      for (const type of events) request.removeEventListener(type, flight.listen);
      if (inFlight.get(request) === flight) inFlight.delete(request);

      const { record, started } = flight;
      // Status 0 means no response arrived, unless the request loaded anyway, as one
      // for a local file does.
      if (failure || (request.status === 0 && !flight.loaded)) {
        finished(record, started, { state: "failed", errorSummary: summary ?? failures[failure] ?? failures.error });
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

    function start(request, state, body) {
      const record = {
        id: newID(),
        method: state.method,
        url: state.url,
        startedAtMilliseconds: now(),
        requestHeaders: { ...state.requestHeaders },
      };
      const captured = requestBody(body, state.requestHeaders["content-type"]);
      const flight = { record, started: clock(), failure: undefined, loaded: false, done: false };
      flight.listen = (event) => {
        if (event.type === "load") flight.loaded = true;
        else if (event.type !== "loadend") flight.failure = event.type;
        // A `loadend` left over from this object's previous request arrives while it
        // is already sending this one, before this one is done.
        else if (request.readyState === 4) safely(() => settle(request, flight, flight.failure));
      };
      for (const type of events) request.addEventListener(type, flight.listen);
      inFlight.set(request, flight);
      post({ ...record, state: "pending" });
      if (captured) record.requestBody = captured;
      return flight;
    }

    const wrappers = {
      open(method, url) {
        // Opening again ends whatever the object was doing. A finished request still
        // holds its answer here, and loses it once `open` runs.
        const flight = inFlight.get(this);
        if (flight) safely(() => settle(this, flight, this.readyState === 4 ? flight.failure : "abort"));

        const result = native.open.apply(this, arguments);
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
      },

      setRequestHeader(name, value) {
        const result = native.setRequestHeader.apply(this, arguments);
        safely(() => {
          const state = opened.get(this);
          if (!state) return;
          // Repeated headers combine, as the browser sends them.
          const key = String(name).toLowerCase();
          const headers = state.requestHeaders;
          headers[key] = key in headers ? `${headers[key]}, ${value}` : String(value);
        });
        return result;
      },

      send() {
        const state = opened.get(this);
        let flight;
        if (state && !inFlight.has(this)) {
          try {
            flight = start(this, state, arguments[0]);
          } catch {
            flight = undefined;
          }
        }
        try {
          return native.send.apply(this, arguments);
        } catch (error) {
          // `send` refused to start, or a synchronous request failed.
          if (flight) safely(() => settle(this, flight, "error", describeError(error)));
          throw error;
        }
      },

      abort() {
        // Aborting a finished request discards its answer, so the record takes it first.
        const flight = inFlight.get(this);
        if (flight && this.readyState === 4) safely(() => settle(this, flight, flight.failure));
        return native.abort.apply(this, arguments);
      },
    };

    // Method syntax again: none of these is a constructor in the browser either.
    for (const name of Object.keys(wrappers)) prototype[name] = wrappers[name];
  }
})();
