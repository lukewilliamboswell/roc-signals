import { mountSignalsApp, publicExampleTaskHandler } from "./signals.mjs";

let uploadedRuntime = null;
let uploadedObjectUrl = null;

async function mountInto(root, wasmUrl, title, errorTarget = null) {
  root.replaceChildren();
  if (errorTarget) {
    errorTarget.hidden = true;
    errorTarget.classList.add("hidden");
  }

  try {
    return await mountSignalsApp({
      wasmUrl,
      root,
      taskHandler: publicExampleTaskHandler,
      onError: (err) => showError(errorTarget, err),
      telemetry: true,
    });
  } catch (err) {
    showError(errorTarget, err);
    throw err;
  }
}

function showError(target, err) {
  if (!target) {
    console.error(err);
    return;
  }
  target.hidden = false;
  target.classList.remove("hidden");
  target.textContent = String(err?.message || err);
}

function setupExampleMounts() {
  for (const mount of document.querySelectorAll("[data-signals-wasm]")) {
    const wasmUrl = mount.dataset.signalsWasm;
    const title = mount.dataset.signalsTitle || "Signals app";
    const error = document.createElement("p");
    error.hidden = true;
    error.className = "hidden border-b border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900";
    mount.before(error);
    mountInto(mount, wasmUrl, title, error).catch(() => {});
  }
}

function setupUpload() {
  const zone = document.querySelector("[data-upload-zone]");
  const input = document.querySelector("[data-upload-input]");
  const error = document.querySelector("[data-upload-error]");
  const runner = document.querySelector("[data-upload-runner]");
  const root = document.querySelector("[data-signals-upload-root]");
  const title = document.querySelector("[data-upload-title]");
  const reset = document.querySelector("[data-upload-reset]");
  const status = document.querySelector("[data-upload-status]");
  if (!zone || !input || !runner || !root || !title || !reset) {
    return;
  }

  const setStatus = (text) => {
    if (status) {
      status.textContent = text;
    }
  };

  const cleanupUploaded = () => {
    uploadedRuntime?.unmount();
    uploadedRuntime = null;
    if (uploadedObjectUrl) {
      URL.revokeObjectURL(uploadedObjectUrl);
      uploadedObjectUrl = null;
    }
  };

  const openFile = async (file) => {
    if (!file) return;
    if (!file.name.toLowerCase().endsWith(".wasm")) {
      showError(error, new Error("Choose a .wasm file built with Roc Signals."));
      return;
    }

    cleanupUploaded();
    const url = URL.createObjectURL(file);
    uploadedObjectUrl = url;
    title.textContent = `Loading ${file.name}`;
    runner.classList.remove("hidden");
    setStatus(`Loading ${file.name}...`);
    runner.scrollIntoView({ block: "start", behavior: "smooth" });

    try {
      uploadedRuntime = await mountInto(root, url, file.name, error);
      title.textContent = file.name;
      setStatus(`${file.name} is running below.`);
    } catch (err) {
      title.textContent = "Upload failed";
      setStatus("Drop app.wasm or choose a file");
      if (uploadedObjectUrl === url) {
        URL.revokeObjectURL(url);
        uploadedObjectUrl = null;
      }
      throw err;
    }
  };

  input.addEventListener("change", () => {
    openFile(input.files?.[0]).catch(() => {});
  });

  const allowDrop = (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (event.dataTransfer) {
      event.dataTransfer.dropEffect = "copy";
    }
    zone.classList.add("ring-2", "ring-emerald-500");
  };

  zone.addEventListener("dragenter", allowDrop);
  zone.addEventListener("dragover", allowDrop);

  zone.addEventListener("dragleave", (event) => {
    event.preventDefault();
    event.stopPropagation();
    zone.classList.remove("ring-2", "ring-emerald-500");
  });

  zone.addEventListener("drop", (event) => {
    event.preventDefault();
    event.stopPropagation();
    zone.classList.remove("ring-2", "ring-emerald-500");
    openFile(event.dataTransfer?.files?.[0]).catch(() => {});
  });

  reset.addEventListener("click", () => {
    cleanupUploaded();
    root.replaceChildren();
    runner.classList.add("hidden");
    setStatus("Drop app.wasm or choose a file");
  });
}

setupExampleMounts();
setupUpload();
