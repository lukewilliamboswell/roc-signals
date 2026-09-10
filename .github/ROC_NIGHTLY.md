# Automatic Roc nightly updates

The scheduled caller runs daily at 13:43 UTC. It selects the latest published
nightly, creates a verified signed pin-only PR, validates its exact commit, and
automatically merges a passing update. Source fixes and release URL changes remain
manually reviewed PRs.

Literal `roc` fields in both platforms and every web and GUI example header
own the compiler pins, including internal web fixtures. `.github/roc-nightly.json` selects these roots and the validation
workflows; it contains no duplicate version authority. The selected pins agree.
The bot changes only their compiler literals, preserving all package/platform URLs.

The required pull-request check is `Platform source`. Development tests bind
temporary copies to current source. Exact combined bundles and their rewritten
example archive are tested from fresh caches by the explicitly dispatched
release workflow rather than rebuilt by ordinary pull-request CI. A failed
released dependency may require a platform patch and a new immutable release
before retrying the nightly.

The caller pins shared automation to `13b98f8428993bf0dcca9fbaa3b7762ec3e25d34`.
Dependabot proposes reviewed reference updates. See the shared
[integration guide](https://github.com/lukewilliamboswell/roc-automation/blob/13b98f8428993bf0dcca9fbaa3b7762ec3e25d34/docs/integration.md)
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
