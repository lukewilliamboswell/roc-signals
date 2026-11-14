// This element owns the browser stream. Roc receives only Starting/Active/Ended.
export function registerCamera() {
  if (customElements.get("recipe-camera")) return;
  customElements.define("recipe-camera", class extends HTMLElement {
    #pending = false;
    #stop = null;
    constructor() {
      super();
      const root = this.attachShadow({ mode: "open" });
      this.video = document.createElement("video");
      this.video.autoplay = true;
      this.video.muted = true;
      this.video.playsInline = true;
      this.video.style.maxWidth = "100%";
      root.append(this.video);
    }
    subscribe(ctx) {
      if (!navigator.mediaDevices?.getUserMedia) throw new Error("Camera capture is unavailable");
      if (this.#pending || this.#stop) throw new Error("The camera already has an owner or a pending permission request");
      let ended = false;
      let stream = null;
      const listeners = [];
      const stop = () => {
        if (ended) return;
        ended = true;
        ctx.signal.removeEventListener("abort", stop);
        for (const [track, listener] of listeners) track.removeEventListener("ended", listener);
        listeners.length = 0;
        if (stream) for (const track of stream.getTracks()) track.stop();
        this.video.srcObject = null;
        if (this.#stop === stop) this.#stop = null;
      };
      this.#stop = stop;
      ctx.signal.addEventListener("abort", stop, { once: true });
      if (ctx.signal.aborted) { stop(); return stop; }
      ctx.emit("Starting");
      this.#pending = true;
      // Browsers cannot cancel a permission dialog. Keep its single pending
      // slot until it settles, and stop tracks from an answer that came late.
      let permission;
      try { permission = navigator.mediaDevices.getUserMedia({ video: true, audio: false }); }
      catch (error) { this.#pending = false; stop(); throw error; }
      Promise.resolve(permission).then((answer) => {
        this.#pending = false;
        if (ended) { for (const track of answer.getTracks()) track.stop(); return; }
        stream = answer;
        for (const track of stream.getTracks()) {
          const listener = () => { stop(); ctx.emit("Ended"); ctx.close(); };
          track.addEventListener("ended", listener, { once: true });
          listeners.push([track, listener]);
        }
        this.video.srcObject = stream;
        ctx.emit("Active");
      }, (error) => {
        this.#pending = false;
        if (!ended) { stop(); ctx.close(error); }
      });
      return stop;
    }
    disconnectedCallback() { this.#stop?.(); }
  });
}

export function mediaPorts(camera) {
  return { "example.org/recipes/camera": { subscribe: (_, ctx) => camera.subscribe(ctx) } };
}
