# Capability-oriented application APIs

## Goal

Make authority explicit in Signals applications: a component can request an
external operation only through a resource capability or callback deliberately
supplied to it. Importing a module supplies operations and types, not authority
to access the filesystem, network, browser environment, or another component's
resources.

Adapt the principles in the
[basic-cli capability proposal](https://gist.githubusercontent.com/lukewilliamboswell/3ce9d0f209f2319ecfb5e91a4fae97c3/raw/32fae000afd033c0d383b5962c52920509cf198e/basic-cli-cap-proposal.md)
to a reactive UI platform. Applications continue to construct pure descriptions;
the host executes effects after engine commit. Capability passing must compose
with ordinary Roc functions, signals, commands, explicit scopes, and retained
callbacks.

This is a plan, not a new public contract. [design.md](../design.md) remains the
architectural authority. Entry-point, resource-lifetime, and transport changes
identified here require deliberate design decisions before implementation.
Current build and test commands belong in
[Contributing](../www/content/docs/contributing.md).

## Objectives

1. **Explicit initial authority.** The host supplies the application's initial
   services as arguments. Applications delegate subsets to components. There is
   no global accessor or callable bootstrap that recovers all process authority.
2. **Narrow delegation.** An editor can receive a reader, one save destination,
   or a specific save callback without receiving arbitrary filesystem access.
   Names select resources within delegated authority; names do not create it.
3. **Host-enforced rights.** Validate resource identity, permitted operations,
   lifetime, and ownership at the host boundary before performing an effect.
   Opaque application types support this contract but cannot enforce it alone.
4. **Pure, transactional effects.** Capability-bearing tasks and commands use the
   existing engine scheduling, scope ownership, pruning, cancellation, and
   publication model. Preparation describes effects; execution follows commit.
5. **Bounded resource ownership.** Every resource has explicit acquisition,
   aliasing, transfer, release, refusal, saturation, and shutdown behavior.
   Scope disposal releases its ownership without invalidating another legitimate
   owner or preserving a disposed scope's work.
6. **One coherent public surface.** Migration removes unrestricted alternate
   routes in the replacement release. Wrapping a path-based API while leaving
   the original authority-acquiring route available does not achieve confinement.
7. **Checkable author outcomes.** Small applications and reusable components
   demonstrate that narrow delegation is practical without resource IDs,
   serialization tricks, or application-authored runtime bookkeeping.

## Existing foundation and gaps

Signals already provides pure commands, typed task failures, explicit effect
routes, bounded workers, cancellation, and scope-owned work. State illustrates
useful delegation: a `Signal(a)` permits observation, a specific message permits
one action, and a state handle permits broader mutation descriptions.

| Surface | Gap to address |
| --- | --- |
| [GUI entry point](../platform-gui/main.roc) | `main` takes no arguments, leaving no explicit initial authority parameter. |
| [Files](../platform-gui/Files.roc) | Choosers return paths; read, write, and scan tasks accept absolute paths using process authority. |
| [Signal task construction](../platform-shared/Signal.roc) | Reachable host-task factories and string request routes must not bypass resource checks. |
| [Browser APIs](../platform-web/Browser.roc) | Environment operations need an authority inventory and deliberate delegation boundaries. |
| Widget registration | A supplied widget name must not grant access to every service in a mount. |
| [Capability(a)](../platform-shared/Capability.roc) | Erased-value ownership and type safety are distinct from authority to use external resources. |

The [native file implementation](../crates/gpui-host/src/file_io.rs) already uses
owned directory handles and refuses symlink traversal. That provides race
resistance, but acquisition from an arbitrary absolute path still starts from
process authority. A delegated root requires a different acquisition contract.

## Scope and assurance

The first implementation target is native Files and a reusable editor. Inventory
the browser and shared task surfaces at the same time so the initial design does
not make their migration impossible. Final public names and signatures remain
open until compiled examples validate the shape.

Define precisely which application and package operations the confinement claim
covers. The host and platform implementation remain trusted. This work does not
by itself sandbox arbitrary native code or establish the trustworthiness of a
prebuilt library. Test the pinned compiler's actual exposed surface, including
hosted declarations, inspection, factories, and descriptor helpers; comments
calling a function internal are not access control.

Independent signed library releases establish build provenance. They are a
separate project with separate acceptance evidence.

## Architectural decisions

### Initial service injection

Specify how the host passes initial authority through `roc_ui_init` to application
`main`. Preserve one initialization call and subsequent retained callbacks. This
changes the documented zero-argument entry-point contract and requires updates
across platform declarations, generated ABI, typed views, hosts, and examples.
Do not approximate injection with an ambient service lookup.

### Resource identity and lifetime

Distinguish permission to operate on a resource, ownership of a resource reference,
and ownership of an in-flight task. Decide how rights can be narrowed and whether
revocation is supported; neither operation should be inferred from ordinary
reference release.

Specify chooser success, abandoned or stale completion, task supersession,
cancellation, scope disposal, independently retained aliases, and shutdown. A
longer-lived owner may retain a resource independently, but a copied reference
must not resurrect a canceled task or extend its disposed scope. Bound live
resources independently of the worker queue. Use indexed validation and
nonwrapping identities, preserving the changed-set work budget.

### Save semantics

Preserve the distinction between an open file and an authorized directory entry.
Current writes atomically replace a named destination. A `SaveTarget` could
represent permission to replace one name within an owned parent; a writer for an
already-open file represents a different operation. Choose and document that
contract before changing the editor's save API.

### Resource transfer across the boundary

A chooser should transfer an opaque resource reference associated with its active
request, rather than returning a publicly reconstructible resource token inside
the `files1` text codec. Specify who owns each reference before and after success,
refusal, allocation failure, stale delivery, and teardown. Resource references
must coexist with capability-owned erased Roc values without exposing their
layout or conflating the two meanings of capability.

### Browser and network authority

Inventory storage, navigation, environment subscriptions, HTTP, and registered
widgets. Define the authority each operation consumes and how it is delegated.
Origin confinement would conflict with current browser-fetch redirect defaults;
an `Http.Client` parameter alone cannot establish it. Resolve redirect and
transport behavior explicitly before promising that restriction.

## Work sequence

### 1. Inventory and executable API examples

List every supported authority-acquiring route, its owner, permitted operations,
and intended replacement. Write small compiled examples for application service
injection and component delegation. Audit whether public construction or
inspection can recover broader authority. Record the assurance boundary and
resolve the decisions above in `design.md` before changing those contracts.

### 2. One complete native Files slice

Implement chooser → opaque reader/save target → component callback. A component
can request a read or describe saving to one captured destination; it cannot
substitute an arbitrary absolute path at task start. A directory capability may
permit relative selection under its explicit traversal policy.

Keep commands pure and execution in the existing host effect path. Complete the
slice through Roc modules, ABI and typed views, shared task ownership, native
adapter, semantic specs, maintained examples, and public documentation. Use
Notes Editor to validate ordinary open, edit, save, cancel, and disposal workflows.

### 3. Failure and authority evidence

Test denial before any unauthorized operation. Cover forbidden writes, relative
path escape, symlink and rename races, narrowed rights, invalid or stale resource
references, repeated actions, independently retained aliases, cancellation,
supersession, scope disposal, saturation, allocation failure, and shutdown.

Use native semantic specs for application behavior and work budgets, focused host
tests for resource ownership and filesystem races, and browser tests for browser
integration contracts. Use sequence fuzzing where aliasing, retirement, and task
completion order interact; mutation-test new fuzz oracles.

### 4. Coherent migration

Migrate the supported Files surface and its examples together. Remove alternate
unrestricted routes, document the source migration, and update protocol and ABI
compatibility information wherever representations change. Apply the same
inventory and evidence process to the agreed browser and network surfaces.
Do not claim platform-wide confinement from a successful editor-only slice.

## Acceptance criteria

- [ ] The application receives explicit host-supplied authority, and a reusable
  component works with a narrower delegated interface.
- [ ] Module imports, paths, inspection, and public task factories cannot recover
  authority outside the documented assurance boundary.
- [ ] The host rejects unauthorized or stale operations before external effects.
- [ ] Commands remain pure descriptions and use the shared propagation and
  post-commit effect model.
- [ ] Resource aliases, task lifetime, scope disposal, cancellation, and shutdown
  have explicit contracts and passing ownership tests.
- [ ] Resource and queue bounds refuse work predictably without leaks, partial
  publication, stale reuse, or scans of unrelated live resources.
- [ ] Notes Editor demonstrates the reader/save-target workflow, including atomic
  replacement and preservation of edits made while a save is in flight.
- [ ] Architectural decisions, public documentation, maintained examples, and
  compatibility guidance describe the same implemented behavior.
- [ ] The authority inventory accounts for every supported route; remaining
  surfaces are explicitly outside the claim rather than hidden bypasses.
