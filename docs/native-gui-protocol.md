# Native GUI presentation boundary

The statically linked GUI boundary uses protocol version **2**. Zig exports
`signals_protocol_version` and `signals_node_size`; Rust checks both before
mount. This version adds checked-event ingress, semantic role/test identifiers,
selection, and typed native presentation. Both sides must be rebuilt together.
The browser protocol and its version are unchanged.

`Gui` lowers native presentation through the shared scalar descriptor machinery.
Text field **8** is `native_style`; boolean field **4** is `selected`. The unused
IDs 7 and 3 remain the existing custom text/bool field markers. Native fields
are explicit protocol fields, not CSS, class names, test identifiers, or custom
attribute conventions. The browser rejects them before reserving or staging a
command batch. Native specs retain them through the ordinary render publication.
The native context also prepares a browser-shaped journal for shared structural
bookkeeping; these two native fields publish only through its typed native
publication and never acquire invented browser opcodes.

The style field contains a canonical ASCII decimal record separated by commas:

```
version,direction,gap,padding,width_kind,width,height_kind,height,grow,background,foreground,border_color,border_width,radius,font_size,overflow_x,overflow_y
```

Version 1 has exactly these 17 fields. Numbers have no signs, whitespace, or
leading zeroes. Direction is row=0 or column=1. Length kind is auto=0, fill=1,
pixels=2; auto/fill must have a zero value. Grow is 0 or 1. Overflow is
visible=0, clip=1, scroll=2. Colors are 24-bit RGB or 16777216 for inherited/default.
Lengths, spacing, radius, borders, and font size are logical pixels, bounded at
16384. Font size zero inherits. Invalid records are programmer-contract errors,
not a request to substitute defaults. Records are bounded at 192 bytes.

The public `Gui.Style` contains typed lengths, colors and overflow tags. Only the
platform encoder creates records. `Gui.row`/`column`/`panel` choose direction;
`Gui.style` and `style_s` describe the remaining fields. Each element accepts one
style attribute. A supplied style replaces the helper's complete default style.
The style signal is an ordinary typed, equality-pruned signal; there is no
native styling observer graph.

Zig validates the style during native publication preparation and exports an
`extern` struct of 16 `u32` fields in the order after `version` above. Rust copies
this validated record along with primitive fields and borrowed UTF-8 data before
any next engine operation. Rust applies the supplied layout and presentation
properties with GPUI. Selected state adds the standard selection border, and
disabled state applies reduced opacity and refuses input dispatch.

`signals_dispatch` accepts event ID, payload kind, UTF-8 pointer/length, and a
boolean word. Kind 0 is unit, kind 1 is text, kind 2 is checked boolean; boolean
payloads require zero text bytes and a value of 0 or 1. Unit payloads require
zero text bytes and a zero boolean word; text payloads require valid UTF-8 and
a zero boolean word. Each kind uses the shared
engine's existing event extraction descriptor and capability-owned reducer path.
Deferred callbacks validate both node identity and current binding, and cannot
update disposed or rebound controls.

Input labels are both visible captions and semantic metadata. Semantic roles,
names, and test IDs support native specs and GPUI test selectors. They do not
establish Linux screen-reader support: the pinned GPUI dependency does not expose
an operating-system accessibility tree.

The host still copies complete child lists for touched parents and enumerates
children during GPUI rendering. Native presentation does not establish the full
O(changed) rendering target; list topology and viewport rendering remain separate
capabilities with their own work budgets.
