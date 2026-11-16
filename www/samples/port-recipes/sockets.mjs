// SSE uses a decimal U64 event id and text data. WebSocket text frames are
// JSON {seq: "decimal U64", data: "text"}. Reconnect policy belongs to Roc.
const NS = "example.org/recipes/";
const MAX_BYTES = 65536;
const MAX_U64 = (1n << 64n) - 1n;
const encoder = new TextEncoder();

function sequence(text) {
  if (typeof text !== "string" || !/^(0|[1-9][0-9]{0,19})$/.test(text) || BigInt(text) > MAX_U64) {
    throw new Error("The feed sequence must be a decimal U64 string");
  }
  return text;
}

// Check before encoding or parsing: one hostile frame cannot cause an
// unbounded copy in this handler. The browser itself already received it.
function boundedText(text) {
  if (typeof text !== "string" || text.length > MAX_BYTES || !text.isWellFormed() || encoder.encode(text).length > MAX_BYTES) {
    throw new Error("A feed frame exceeds 64 KiB or is not well-formed text");
  }
  return text;
}

export function socketPorts() {
  let primary = null;

  function connect(input, ctx, websocket) {
    const url = new URL(input.url, location.href);
    url.searchParams.set("after", sequence(input.after));
    if (websocket) url.protocol = url.protocol === "https:" ? "wss:" : url.protocol === "http:" ? "ws:" : url.protocol;
    if (websocket && primary) throw new Error("The primary WebSocket is already open");
    const source = websocket ? new WebSocket(url) : new EventSource(url);
    if (websocket) primary = source;
    let ended = false, opened = false, frame = null, timer = null;
    let bytes = 0, dropped = 0n;
    const queue = [];

    const unschedule = () => {
      if (frame !== null) cancelAnimationFrame(frame);
      if (timer !== null) clearTimeout(timer);
      frame = timer = null;
    };
    const stop = () => {
      if (ended) return;
      ended = true;
      unschedule();
      ctx.signal.removeEventListener("abort", stop);
      source.onopen = source.onmessage = source.onerror = source.onclose = null;
      source.close();
      if (primary === source) primary = null;
      queue.length = 0;
      bytes = 0;
    };
    const finish = (error) => { stop(); ctx.close(error); };
    const schedule = () => {
      if (ended || frame !== null || timer !== null) return;
      // One fallback timer also makes progress when hidden tabs suspend frames.
      frame = requestAnimationFrame(drain);
      timer = setTimeout(drain, 100);
    };
    function drain() {
      unschedule();
      if (ended) return;
      let sent = 0;
      if (opened) {
        if (!ctx.emit("Opened")) { schedule(); return; }
        opened = false;
        sent = 8;
      }
      while (queue.length && sent + queue[0].bytes <= MAX_BYTES) {
        const next = queue[0];
        if (!ctx.emit({ Event: { seq: next.seq, data: next.data, dropped: dropped.toString() } })) break;
        queue.shift();
        bytes -= next.bytes;
        sent += next.bytes;
      }
      if (queue.length) schedule();
    }
    source.onopen = () => { opened = true; schedule(); };
    source.onmessage = (event) => {
      try {
        const text = boundedText(event.data);
        const value = websocket ? JSON.parse(text) : { seq: event.lastEventId, data: text };
        const seq = sequence(value.seq);
        const data = boundedText(value.data);
        // Budget the complete outgoing JSON, including the largest drop count.
        const size = encoder.encode(JSON.stringify({ Event: { seq, data, dropped: MAX_U64.toString() } })).length;
        if (size > MAX_BYTES) throw new Error("The encoded feed message exceeds 64 KiB");
        while (queue.length >= 64 || bytes + size > MAX_BYTES) {
          bytes -= queue.shift().bytes;
          if (dropped === MAX_U64) throw new Error("The feed drop counter is exhausted");
          dropped += 1n;
        }
        queue.push({ seq, data, bytes: size });
        bytes += size;
        schedule();
      } catch (error) { finish(error); }
    };
    // Closing first prevents EventSource's automatic reconnect from competing
    // with the app's scoped backoff timer.
    source.onerror = () => finish(new Error("The live connection failed"));
    if (websocket) source.onclose = (event) => finish(event.wasClean ? undefined : new Error(`WebSocket closed with code ${event.code}`));
    ctx.signal.addEventListener("abort", stop, { once: true });
    if (ctx.signal.aborted) stop();
    return stop;
  }

  return {
    [`${NS}sse`]: { subscribe: (input, ctx) => connect(input, ctx, false) },
    [`${NS}websocket`]: { subscribe: (input, ctx) => connect(input, ctx, true) },
    [`${NS}socket-send`]: { command: ({ connection, data }) => {
      if (connection !== "primary") throw new Error("Unknown connection name");
      if (primary?.readyState === WebSocket.OPEN) {
        const text = boundedText(data);
        if (primary.bufferedAmount + encoder.encode(text).length > MAX_BYTES) throw new Error("The socket send buffer is full");
        primary.send(text);
      }
    } },
  };
}
