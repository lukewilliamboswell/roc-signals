# Automatic Roc nightly updates

The scheduled caller runs daily at 13:43 UTC. It selects the latest published
nightly, creates a verified signed pin-only PR, validates its exact commit, and
automatically merges a passing update. Source fixes and release URL changes remain
manually reviewed PRs.

Literal `roc` fields in the platform and all public application headers own the
compiler pins. `.github/roc-nightly.json` selects these roots and the validation
workflows; it contains no duplicate version authority. The selected pins agree.
The bot changes only their compiler literals, preserving all package/platform URLs.

The required checks are `Published examples`, `Platform source`, and
`Release archive`. Published tests use committed URLs and fresh caches;
development tests rebind temporary copies to current source. A failed released
dependency may require a platform patch, a new immutable release, and a reviewed
example-URL update before retrying the nightly. Local success never substitutes
for a passing download.

The caller pins shared automation to `31e10eca5b0f7e4cacbf7864d51dfa8d224ae30f`.
Dependabot proposes reviewed reference updates. See the shared
[integration guide](https://github.com/lukewilliamboswell/roc-automation/blob/31e10eca5b0f7e4cacbf7864d51dfa8d224ae30f/docs/integration.md)
for the strict ruleset and signature checks. Automatic merging requires active
pull-request and up-to-date required-check rules, Actions PR creation, and no bot
bypass. Default token permissions stay read-only; candidate test jobs receive no
publication, merge, or deployment authority.

`automation/roc-nightly` is reserved for pin-only bot commits. The updater never
approves PRs, publishes releases, or deploys Pages. Compiler bumps do not rebuild
immutable release starters or versioned documentation.

Keep successful merge, no-op, failure, and signed release-follow-up evidence in
the rollout PR. Configuration files alone do not prove live acceptance or OpenSSF
compliance. Release setup and recovery are documented in the contributor guide.
