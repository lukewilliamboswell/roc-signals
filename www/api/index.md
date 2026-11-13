# Roc Signals API

The modules the web platform exposes to apps:

- `Engine`: programs, values, the store with its cells, writes and
  decisions, local state and handlers, structure, keyed lists, views of a
  table, and effects.
- `Table`: the rows a table cell of the store holds, by key, and the
  operations that write them.
- `Html`: typed HTML elements, attributes and events over `Engine.element`.
- `Clipboard`: plain-text or text-and-HTML writes, with a typed outcome.
- `Worker`: tasks run in Web Workers, and the layers that show their
  answers. `Wire` is the binary format their inputs and outputs cross in,
  derived from their types, and `Files` builds a file in a job.
- `Port`: typed messages to JavaScript the page supplies. `PortJson` is the
  format they cross in, derived from their types.

The [guide](https://lukewilliamboswell.github.io/roc-signals/docs/guide/)
teaches how they fit together.
