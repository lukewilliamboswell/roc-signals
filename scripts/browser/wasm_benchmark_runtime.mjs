import { SignalsRuntime } from "../../www/static/signals.mjs";

const PHASES = ["wasm_event_ns", "command_read_ns", "command_snapshot_ns", "command_execute_ns"];
export const OPCODE_NAMES = [
  "reset_dom", "create_element", "create_text", "append_child", "remove_node", "move_before",
  "set_text", "set_value", "set_checked", "set_disabled", "set_role", "set_label", "set_test_id",
  "bind_click", "bind_input", "bind_check", "clear_event", "start_interval", "cancel_interval",
  "start_task", "cancel_task", "set_class", "bind_pointer_down", "bind_pointer_up",
  "bind_pointer_enter", "bind_pointer_leave", "extended", "push_state", "replace_state",
  "set_storage_text", "remove_storage", "set_document_title",
];

export class BenchmarkPhaseRecorder {
  constructor(clock = () => process.hrtime.bigint()) {
    this.clock = clock;
    this.active = false;
    this.reset();
  }

  reset() {
    this.timings = Object.fromEntries(PHASES.map((name) => [name, 0n]));
    this.calls = Object.fromEntries(PHASES.map((name) => [name, 0]));
    this.event_total_ns = 0n;
    this.eventCalls = 0;
    this.work = {
      command_count: 0,
      fixed_record_count: 0,
      fixed_record_words: 0,
      fixed_record_bytes: 0,
      fixed_string_bytes: 0,
      dynamic_bytes: 0,
      copied_buffers: 0,
      copied_bytes: 0,
      materialized_command_objects: 0,
      abstract_host_operations: 0,
      opcode_counts: Object.fromEntries(OPCODE_NAMES.map((name) => [name, 0])),
      decode: {},
    };
  }

  begin() {
    this.reset();
    this.active = true;
  }

  measure(name, action) {
    if (!this.active) return action();
    const start = this.clock();
    try {
      return action();
    } finally {
      this.timings[name] += this.clock() - start;
      this.calls[name] += 1;
    }
  }

  measureEvent(action) {
    if (!this.active) throw new Error("benchmark event timing began before metrics reset");
    const start = this.clock();
    try {
      return action();
    } finally {
      this.event_total_ns += this.clock() - start;
      this.eventCalls += 1;
    }
  }

  finish() {
    this.active = false;
    if (this.eventCalls !== 1) throw new Error(`benchmark sample requires one marked event, observed ${this.eventCalls}`);
    for (const name of ["wasm_event_ns", "command_read_ns", "command_execute_ns"]) {
      if (this.calls[name] !== 1) throw new Error(`benchmark phase ${name} must execute once, observed ${this.calls[name]}`);
    }
    if (this.calls.command_snapshot_ns > 1) {
      throw new Error(`benchmark phase command_snapshot_ns executed ${this.calls.command_snapshot_ns} times`);
    }
    const nested = PHASES.reduce((total, name) => total + this.timings[name], 0n);
    if (nested > this.event_total_ns) {
      throw new Error(`benchmark nested phases exceed event total: phases=${nested} total=${this.event_total_ns}`);
    }
    return {
      event_total_ns: this.event_total_ns,
      ...this.timings,
      event_residual_js_ns: this.event_total_ns - nested,
      ...this.work,
    };
  }
}

function benchmarkExports(exports, recorder) {
  const event = exports.roc_ui_event;
  return {
    ...exports,
    roc_ui_event: (...args) => recorder.measure("wasm_event_ns", () => event(...args)),
  };
}

export class BenchmarkSignalsRuntime extends SignalsRuntime {
  constructor(exports, root, options = {}) {
    const recorder = options.recorder ?? new BenchmarkPhaseRecorder(options.clock);
    super(benchmarkExports(exports, recorder), root, { ...options, telemetry: undefined });
    this.benchmarkRecorder = recorder;
  }

  readPendingCommands() {
    const records = this.benchmarkRecorder.measure("command_read_ns", () => super.readPendingCommands());
    if (this.benchmarkRecorder.active) {
      this.benchmarkRecorder.work.materialized_command_objects += records.length;
    }
    return records;
  }

  snapshotCommandBuffers() {
    const buffers = this.benchmarkRecorder.measure("command_snapshot_ns", () => super.snapshotCommandBuffers());
    if (this.benchmarkRecorder.active) {
      this.benchmarkRecorder.work.copied_buffers += 2;
      for (const bytes of [buffers.strings, buffers.dynamic]) {
        this.benchmarkRecorder.work.copied_bytes += bytes.byteLength;
      }
    }
    return buffers;
  }

  applyPendingCommands(phase = "host-call") {
    if (!this.benchmarkRecorder.active) return super.applyPendingCommands(phase);
    const readBefore = this.benchmarkRecorder.timings.command_read_ns;
    const snapshotBefore = this.benchmarkRecorder.timings.command_snapshot_ns;
    const start = this.benchmarkRecorder.clock();
    const result = super.applyPendingCommands(phase);
    const elapsed = this.benchmarkRecorder.clock() - start;
    const nestedRead = this.benchmarkRecorder.timings.command_read_ns - readBefore;
    const nestedSnapshot = this.benchmarkRecorder.timings.command_snapshot_ns - snapshotBefore;
    if (nestedRead + nestedSnapshot > elapsed) throw new Error("command read/snapshot time exceeds applyPendingCommands duration");
    this.benchmarkRecorder.timings.command_execute_ns += elapsed - nestedRead - nestedSnapshot;
    this.benchmarkRecorder.calls.command_execute_ns += 1;
    return result;
  }

  applyCommand(record) {
    const result = super.applyCommand(record);
    if (this.benchmarkRecorder.active) this.benchmarkRecorder.work.abstract_host_operations += 1;
    return result;
  }

  emitCommandTelemetry(_phase, records) {
    if (!this.benchmarkRecorder.active) return;
    const work = this.benchmarkRecorder.work;
    work.command_count += records.length;
    work.fixed_record_count += records.length;
    work.fixed_record_words = this.exports.roc_ui_command_record_words();
    work.fixed_record_bytes += records.length * this.exports.roc_ui_command_record_words() * 4;
    work.fixed_string_bytes += this.exports.roc_ui_string_buffer_len();
    work.dynamic_bytes += this.exports.roc_ui_dynamic_buffer_len();
    for (const record of records) {
      const name = OPCODE_NAMES[record.op - 1];
      if (name === undefined) throw new Error(`benchmark observed unknown command opcode ${record.op}`);
      work.opcode_counts[name] += 1;
    }
  }

  emitTelemetry(kind, detail = {}) {
    if (kind === "commands_applied" && this.benchmarkRecorder.active) {
      this.benchmarkRecorder.work.decode = { ...detail.decode };
    }
  }

  benchmarkRuntimeState() {
    return {
      live_nodes: this.nodes.size,
      listeners: this.eventCleanups.size,
      behaviors: this.behaviorInstances.size,
      tasks: this.tasks.size,
      intervals: this.intervals.size,
      host_values: this.liveHostValues(),
      wasm_pages: this.exports.memory.buffer.byteLength / 65536,
    };
  }
}
