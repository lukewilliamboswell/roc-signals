app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

## Onboarding Wizard — four steps, eight state handles, zero stored validation.
##
## The point of this example is that a multi-step form does *not* need a wizard
## god-record. Every step owns its own small `Ui.state`, and the two places that
## genuinely need to see across steps use the primitives built for that:
##
##   * `State.on_str_with` / `State.on_unit_with` let one reducer read a second
##     handle atomically. `Next step` is a per-step button whose reducer reads
##     that step's own state and refuses to advance while it is invalid, and the
##     invite-role radios read the organisation's plan to reject a role the plan
##     does not include.
##   * `State.set_cmd` turns a value into a `Node.Cmd`, so a signal change can
##     write retained state. Three uses here: restoring a saved draft on mount,
##     clamping the invite role when the plan changes underneath it, and
##     resetting every handle from one "Start over" click.
##   * Nothing in the wizard is stringly typed. `Plan`, `Region`, `Role` and
##     `Step` are nominal tag unions with an `is_eq` (so they can be signal
##     state) and a `to_str`/`from_str` pair. The `Str` form exists only at the
##     boundaries: the `<option>`/radio value, the saved draft, and the submit
##     request. Everything in between matches on tags.
##
## The signal graph:
##
##     account ──> account_valid ─┐
##     org ──────> org_valid ─────┼─> can_submit ──> submit_disabled
##     emails ───> invites_valid ─┘        │
##                                         └─> progress_complete
##
##     account ──> account_summary ─┐
##     org ──────> org_summary ─────┼─> Signal.combine ──> summaries ──> Ui.each
##     emails/role > invites_summary ┤
##     can_submit > review_summary ──┘
##
## `can_submit` is a four-hop chain from a source (`account` -> `account_valid`
## -> `can_submit` -> `submit_disabled`) and a three-way fan-in via
## `Signal.combine`. `summaries` is a second `Signal.combine` fan-in, and it is
## the one that proves fine-grained updates: editing the organisation name
## recomputes `org_summary` and the combined list, but the account row's text
## sink never fires because its item value is unchanged.
##
## Two documented product decisions:
##
##   * **Changing the plan resets the invite role**, it does not merely hide the
##     option. Picking `Billing admin` on Enterprise and then dropping to
##     Starter leaves the role at `Member`; going back to Enterprise does *not*
##     restore `Billing admin`. The reset is a real state write (`set_cmd`) so
##     the value the user sees is the value that gets submitted and saved.
##   * **Jumping is backwards-only.** The progress list lets you return to any
##     earlier step; moving forward always goes through `Next step`, which is
##     the only thing that validates.

import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

draft_key : Str
draft_key = "onboarding:draft"

# --- domain -----------------------------------------------------------------

## The plan chosen in step 2. It decides which invite roles step 3 offers, so
## it is a closed set: the `<option>` text is a rendering of it, not the value.
Plan := [Starter, Growth, Enterprise].{
	is_eq : Plan, Plan -> Bool
	is_eq = |left, right|
		match left {
			Starter => match right {
				Starter => True
				_ => False
			}
			Growth => match right {
				Growth => True
				_ => False
			}
			Enterprise => match right {
				Enterprise => True
				_ => False
			}
		}

	## The wire form: the `<option>` value, and field 4 of a saved draft.
	to_str : Plan -> Str
	to_str = |plan|
		match plan {
			Starter => "starter"
			Growth => "growth"
			Enterprise => "enterprise"
		}

	## Anything unrecognised is the entry-level plan, so a corrupt draft can
	## never grant a role the account has not paid for.
	from_str : Str -> Plan
	from_str = |text|
		if text == "growth" {
			Plan.Growth
		} else if text == "enterprise" {
			Plan.Enterprise
		} else {
			Plan.Starter
		}

	label : Plan -> Str
	label = |plan|
		match plan {
			Starter => "Starter"
			Growth => "Growth"
			Enterprise => "Enterprise"
		}
}

## Where the workspace's data lives. `Unset` is the un-chosen state, which is
## what makes step 2 incomplete; it has no radio of its own.
Region := [Unset, UnitedStates, EuropeanUnion].{
	is_eq : Region, Region -> Bool
	is_eq = |left, right|
		match left {
			Unset => match right {
				Unset => True
				_ => False
			}
			UnitedStates => match right {
				UnitedStates => True
				_ => False
			}
			EuropeanUnion => match right {
				EuropeanUnion => True
				_ => False
			}
		}

	to_str : Region -> Str
	to_str = |region|
		match region {
			Unset => ""
			UnitedStates => "us"
			EuropeanUnion => "eu"
		}

	from_str : Str -> Region
	from_str = |text|
		if text == "us" {
			Region.UnitedStates
		} else if text == "eu" {
			Region.EuropeanUnion
		} else {
			Region.Unset
		}

	label : Region -> Str
	label = |region|
		match region {
			Unset => "not chosen"
			UnitedStates => "United States"
			EuropeanUnion => "European Union"
		}
}

## The role every invited teammate gets. Which ones are offered is the plan's
## business (see `plan_includes`).
Role := [Member, Admin, Billing].{
	is_eq : Role, Role -> Bool
	is_eq = |left, right|
		match left {
			Member => match right {
				Member => True
				_ => False
			}
			Admin => match right {
				Admin => True
				_ => False
			}
			Billing => match right {
				Billing => True
				_ => False
			}
		}

	to_str : Role -> Str
	to_str = |role|
		match role {
			Member => "member"
			Admin => "admin"
			Billing => "billing"
		}

	from_str : Str -> Role
	from_str = |text|
		if text == "admin" {
			Role.Admin
		} else if text == "billing" {
			Role.Billing
		} else {
			Role.Member
		}

	label : Role -> Str
	label = |role|
		match role {
			Member => "Member"
			Admin => "Admin"
			Billing => "Billing admin"
		}
}

## The four steps, in order. `index` is the only place the ordering is written
## down; the progress bar, the backwards-only jump and the validity lookup all
## read it from here.
Step := [AccountStep, OrgStep, InvitesStep, ReviewStep].{
	is_eq : Step, Step -> Bool
	is_eq = |left, right|
		match left {
			AccountStep => match right {
				AccountStep => True
				_ => False
			}
			OrgStep => match right {
				OrgStep => True
				_ => False
			}
			InvitesStep => match right {
				InvitesStep => True
				_ => False
			}
			ReviewStep => match right {
				ReviewStep => True
				_ => False
			}
		}

	index : Step -> U64
	index = |step|
		match step {
			AccountStep => 0
			OrgStep => 1
			InvitesStep => 2
			ReviewStep => 3
		}

	## The wire form: field 8 of a saved draft, and the `Ui.each` row key.
	slug : Step -> Str
	slug = |step|
		match step {
			AccountStep => "account"
			OrgStep => "organisation"
			InvitesStep => "invites"
			ReviewStep => "review"
		}

	from_slug : Str -> Step
	from_slug = |text|
		if text == "organisation" {
			Step.OrgStep
		} else if text == "invites" {
			Step.InvitesStep
		} else if text == "review" {
			Step.ReviewStep
		} else {
			Step.AccountStep
		}

	title : Step -> Str
	title = |step|
		match step {
			AccountStep => "Account"
			OrgStep => "Organisation"
			InvitesStep => "Team invites"
			ReviewStep => "Review"
		}

	## The `Back` button. Step 1 is its own predecessor, which is why the
	## button is disabled there rather than wrapping around.
	previous : Step -> Step
	previous = |step|
		match step {
			AccountStep => Step.AccountStep
			OrgStep => Step.AccountStep
			InvitesStep => Step.OrgStep
			ReviewStep => Step.InvitesStep
		}
}

## A plan survives the round trip through its wire form unchanged.
expect Plan.to_str(Plan.from_str("enterprise")) == "enterprise"

## An unrecognised plan falls back to Starter rather than failing the parse.
expect Plan.is_eq(Plan.from_str("nonsense"), Plan.Starter)

## The unset region is spelled as the empty wire value, so a blank draft round trips.
expect Region.to_str(Region.from_str("")) == ""

## The human-facing region label is a separate projection from the wire value.
expect Region.label(Region.from_str("eu")) == "European Union"

## A role survives the round trip through its wire form unchanged.
expect Role.to_str(Role.from_str("billing")) == "billing"

## A step survives the round trip through the slug used in saved drafts.
expect Step.slug(Step.from_slug("review")) == "review"

## Stepping back from the last step lands on the third step, one before it.
expect Step.index(Step.previous(Step.ReviewStep)) == 2

Account : { email : Str, full_name : Str }
Org : { name : Str, plan : Plan, region : Region }
StepSummary : { step : Step, detail : Str, done : Bool }

empty_account : Account
empty_account = { email: "", full_name: "" }

empty_org : Org
empty_org = { name: "", plan: Plan.Starter, region: Region.Unset }

default_role : Role
default_role = Role.Member

first_step : Step
first_step = Step.AccountStep

valid_email : Str -> Bool
valid_email = |raw| {
	text = raw.trim()
	parts = text.split_on("@")
	match parts.get(1) {
		Ok(domain) => (parts.len() == 2) and (!text.starts_with("@")) and domain.contains(".") and (!domain.starts_with(".")) and (!domain.ends_with("."))
		Err(_) => False
	}
}

## Invite addresses are one comma-separated line. Blank is allowed: a team of
## one is a legitimate way to finish onboarding.
invite_list : Str -> List(Str)
invite_list = |raw|
	raw.split_on(",").map(|part| part.trim()).keep_if(|part| !part.is_empty())

bad_invites : Str -> List(Str)
bad_invites = |raw| invite_list(raw).keep_if(|part| !valid_email(part))

## An ordinary address with a dotted domain is accepted.
expect valid_email("ana@example.com")

## An address with nothing after the `@` is rejected.
expect !valid_email("ana@")

## A domain that ends in a dot is rejected.
expect !valid_email("ana@example.")

## The invite line tolerates surrounding spaces and empty slots between commas.
expect invite_list(" a@b.co , , c@d.co ") == ["a@b.co", "c@d.co"]

account_ok : Account -> Bool
account_ok = |value| valid_email(value.email) and (!value.full_name.trim().is_empty())

org_ok : Org -> Bool
org_ok = |value| (!value.name.trim().is_empty()) and (!Region.is_eq(value.region, Region.Unset))

invites_ok : Str -> Bool
invites_ok = |raw| bad_invites(raw).is_empty()

## Which invite roles a plan includes. Starter is a single-role plan, which is
## what makes the cross-step dependency observable.
plan_includes : Plan, Role -> Bool
plan_includes = |plan, role|
	match role {
		Member => True
		Admin => !Plan.is_eq(plan, Plan.Starter)
		Billing => Plan.is_eq(plan, Plan.Enterprise)
	}

## Every plan offers the plain member role, including the cheapest one.
expect plan_includes(Plan.Starter, Role.Member)

## Starter is the single-role plan, so admin is not on offer there.
expect !plan_includes(Plan.Starter, Role.Admin)

## Growth adds the admin role on top of member.
expect plan_includes(Plan.Growth, Role.Admin)

## Billing admin stays out of reach on Growth.
expect !plan_includes(Plan.Growth, Role.Billing)

## Only Enterprise offers the billing admin role.
expect plan_includes(Plan.Enterprise, Role.Billing)

## The submit request crosses the host boundary as text, so the attempt number
## is encoded in exactly one place. Attempt 0 is "never submitted" and is not
## sent at all.
submit_request_text : U64 -> Str
submit_request_text = |attempt| "submit-${attempt.to_str()}"

## The attempt number is carried in the request text, so a retry is a new request.
expect submit_request_text(2) == "submit-2"

# --- draft serialization -----------------------------------------------------

Draft : { account : Account, org : Org, emails : Str, role : Role, step : Step }

## `|` is the field separator, so it can never appear inside a field.
safe_field : Str -> Str
safe_field = |text| Str.join_with(text.split_on("|"), " ")

serialize_draft : Draft -> Str
serialize_draft = |value|
	Str.join_with(
		[
			safe_field(value.account.email),
			safe_field(value.account.full_name),
			safe_field(value.org.name),
			Plan.to_str(value.org.plan),
			Region.to_str(value.org.region),
			safe_field(value.emails),
			Role.to_str(value.role),
			Step.slug(value.step),
		],
		"|",
	)

blank_draft : Str
blank_draft = serialize_draft(empty_draft)

## A draft with the wrong shape is ignored rather than half-applied, so the
## parse result is a `Try` and the eight `?`s below are the shape check.
ParsedDraft : Try(Draft, [BadDraft, OutOfBounds])

empty_draft : Draft
empty_draft = { account: empty_account, org: empty_org, emails: "", role: default_role, step: first_step }

no_draft : ParsedDraft
no_draft = Err(BadDraft)

## The draft that was actually restored, or the empty form.
draft_or_empty : ParsedDraft -> Draft
draft_or_empty = |parsed|
	match parsed {
		Ok(draft) => draft
		Err(_) => empty_draft
	}

parse_draft : Str -> ParsedDraft
parse_draft = |text| {
	parts = text.split_on("|")
	if parts.len() != 8 {
		Err(BadDraft)
	} else {
		plan = Plan.from_str(parts.get(3)?)
		role = Role.from_str(parts.get(6)?)
		Ok(
			{
				account: { email: parts.get(0)?, full_name: parts.get(1)? },
				org: { name: parts.get(2)?, plan, region: Region.from_str(parts.get(4)?) },
				emails: parts.get(5)?,
				role: if plan_includes(plan, role) { role } else { default_role },
				step: Step.from_slug(parts.get(7)?),
			},
		)
	}
}

## A missing, unavailable, or corrupt value parses to an `Err`, so the empty
## form is left alone rather than half-populated.
read_draft : Browser.StorageText -> ParsedDraft
read_draft = |stored|
	match stored {
		StorageValue(text) => parse_draft(text)
		StorageMissing => Err(BadDraft)
		StorageUnavailable(_) => Err(BadDraft)
	}

## An empty draft round trips, so the blank form is saved and restored unchanged.
expect serialize_draft(draft_or_empty(parse_draft(blank_draft))) == blank_draft

## A fully populated draft round trips, so the wire form survives the tag types on both sides.
expect serialize_draft(draft_or_empty(parse_draft("a@b.co|Ana|Northwind|growth|eu|c@d.co|admin|invites"))) == "a@b.co|Ana|Northwind|growth|eu|c@d.co|admin|invites"

## A role the plan does not include is dropped back to the default.
expect draft_or_empty(parse_draft("a@b.co|Ana|Northwind|starter|eu||billing|invites")).role.is_eq(Role.Member)

## Too few fields is not a half-draft.
expect parse_draft("a@b.co|Ana") == Err(BadDraft)

# --- validation messages (derived, never stored) ------------------------------

email_message : Account -> Str
email_message = |value|
	if value.email.trim().is_empty() {
		"Work email is required."
	} else if !valid_email(value.email) {
		"Work email must look like name@example.com."
	} else {
		"Work email looks good."
	}

full_name_message : Account -> Str
full_name_message = |value|
	if value.full_name.trim().is_empty() {
		"Full name is required."
	} else {
		"Full name looks good."
	}

org_name_message : Org -> Str
org_name_message = |value|
	if value.name.trim().is_empty() {
		"Organisation name is required."
	} else {
		"Organisation name looks good."
	}

region_message : Org -> Str
region_message = |value|
	if Region.is_eq(value.region, Region.Unset) {
		"Choose a data region."
	} else {
		"Data stored in ${Region.label(value.region)}."
	}

invite_message : Str -> Str
invite_message = |raw| {
	bad = bad_invites(raw)
	match bad.first() {
		Ok(first) => "Not a valid email: ${first}"
		Err(_) => {
			count = invite_list(raw).len()
			if count == 0 {
				"No invites yet. You can add teammates later."
			} else {
				"${count.to_str()} invite(s) ready."
			}
		}
	}
}

role_message : Plan, Role -> Str
role_message = |plan, role|
	match plan {
		Starter => "Starter plans have one role. Upgrade to invite admins."
		Growth => "Growth plans include Member and Admin."
		Enterprise => "Enterprise plans include Member, Admin and Billing admin. Current: ${Role.label(role)}."
	}

# --- summaries ---------------------------------------------------------------

account_summary_of : Account -> StepSummary
account_summary_of = |value| {
	step: Step.AccountStep,
	detail: if value.email.trim().is_empty() { "No email yet" } else { "${value.email.trim()} / ${value.full_name.trim()}" },
	done: account_ok(value),
}

org_summary_of : Org -> StepSummary
org_summary_of = |value| {
	step: Step.OrgStep,
	detail: if value.name.trim().is_empty() { "No organisation yet" } else { "${value.name.trim()} on ${Plan.label(value.plan)} in ${Region.label(value.region)}" },
	done: org_ok(value),
}

invites_summary_of : Str, Role -> StepSummary
invites_summary_of = |raw, role| {
	step: Step.InvitesStep,
	detail: "${invite_list(raw).len().to_str()} invite(s) as ${Role.label(role)}",
	done: invites_ok(raw),
}

review_summary_of : Bool -> StepSummary
review_summary_of = |ready| {
	step: Step.ReviewStep,
	detail: if ready { "Ready to create the workspace" } else { "Finish the earlier steps first" },
	done: ready,
}

summary_line : StepSummary -> Str
summary_line = |value| "${Step.title(value.step)}: ${value.detail} (${if value.done { "complete" } else { "incomplete" }})"

## A ready review row reads as complete and says the workspace can be created.
expect summary_line(review_summary_of(True)) == "Review: Ready to create the workspace (complete)"

## The invites row counts the addresses and names the role they will be invited as.
expect summary_line(invites_summary_of("a@b.co, c@d.co", Role.Billing)) == "Team invites: 2 invite(s) as Billing admin (complete)"

complete_count : List(StepSummary) -> U64
complete_count = |rows| rows.keep_if(|row| row.done).len()

# --- classes -----------------------------------------------------------------

page_class : Str
page_class = "app-shell app-shell-narrow"

panel_class : Str
panel_class = "panel grid gap-4 p-5"

row_class : Str
row_class = "flex flex-wrap items-center justify-between gap-3 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2"

input_class : Str
input_class = "input"

textarea_class : Str
textarea_class = "input textarea"

note_class : Str
note_class = "muted"

hint_class : Str
hint_class = "hint"

step_title_class : Str
step_title_class = "panel-title"

## A validation note reads as a neutral requirement until the field has been
## touched. The tone is decided by whether the field has input, never by
## reading the sentence it is about to tint.
note_tone : Bool -> Str
note_tone = |touched|
	if touched {
		"text-xs font-medium text-red-600"
	} else {
		hint_class
	}

# --- app ---------------------------------------------------------------------

main : () -> Elem
main = || {
	Ui.state(
		first_step,
		|step|
			Ui.state(
				empty_account,
				|account|
					Ui.state(
						empty_org,
						|org|
							Ui.state(
								"",
								|emails|
									Ui.state(
										default_role,
										|role|
											Ui.state(
												0.U64,
												|attempts|
													Ui.state(
														0.U64,
														|reset_token|
															Ui.state(
																no_draft,
																|inbox|
																	wizard(
																		{
																			step,
																			account,
																			org,
																			emails,
																			role,
																			attempts,
																			reset_token,
																			inbox,
																		},
																	),
															),
													),
											),
									),
							),
					),
			),
	)
}

Handles : {
	step : Ui.State(Step),
	account : Ui.State(Account),
	org : Ui.State(Org),
	emails : Ui.State(Str),
	role : Ui.State(Role),
	attempts : Ui.State(U64),
	reset_token : Ui.State(U64),
	inbox : Ui.State(ParsedDraft),
}

wizard : Handles -> Elem
wizard = |h| {
	restored = Browser.local_storage_text(draft_key).map(read_draft)
	submit_task = Signal.fake_task("onboarding-submit", |value| value, |err| err)
	reset_signal = h.reset_token.signal()
	inbox_signal = h.inbox.signal()
	step_signal = h.step.signal()
	account_signal = h.account.signal()
	org_signal = h.org.signal()
	emails_signal = h.emails.signal()
	role_signal = h.role.signal()
	attempts_signal = h.attempts.signal()
	plan_signal = org_signal.map(|value| value.plan)

	# --- derived validity: three independent signals that fan into one gate ---
	account_valid = account_signal.map(account_ok)
	org_valid = org_signal.map(org_ok)
	invites_valid = emails_signal.map(invites_ok)

	can_submit : Signal.Signal(Bool)
	can_submit = Signal.combine([account_valid, org_valid, invites_valid]).map(|flags| !flags.contains(False))

	# --- derived summaries: a second fan-in, one row per step ----------------
	summaries : Signal.Signal(List(StepSummary))
	summaries =
		Signal.combine(
			[
				account_signal.map(account_summary_of),
				org_signal.map(org_summary_of),
				Signal.map2(emails_signal, role_signal, invites_summary_of),
				can_submit.map(review_summary_of),
			],
		)

	progress_label = step_signal.map(|current| "Step ${(Step.index(current) + 1).to_str()} of 4 — ${Step.title(current)}")
	progress_complete = summaries.map(|rows| "${complete_count(rows).to_str()} of 4 steps complete")
	progress_attr = summaries.map(|rows| complete_count(rows).to_str())

	step_valid =
		Signal.map2(
			step_signal,
			Signal.combine([account_valid, org_valid, invites_valid, can_submit]),
			|current, flags| match flags.get(Step.index(current)) {
				Ok(flag) => flag
				Err(_) => False
			},
		)
	nav_status =
		Signal.map2(
			step_signal,
			step_valid,
			|current, ok|
				if Step.is_eq(current, Step.ReviewStep) {
					if ok { "Everything checks out. Create the workspace." } else { "Go back and finish the incomplete steps." }
				} else if ok {
					"Ready for the next step."
				} else {
					"Complete this step to continue."
				},
		)

	# --- the plan clamps the invite role. Reset, not hide: the value the user
	# --- sees is the value that is saved and submitted.
	clamped_role = Signal.map2(role_signal, plan_signal, |current, plan| if plan_includes(plan, current) { current } else { default_role })

	# --- draft persistence ---------------------------------------------------
	whole : Signal.Signal(Draft)
	whole =
		{
			account: account_signal,
			org: org_signal,
			emails: emails_signal,
			role: role_signal,
			step: step_signal,
		}.Signal
	draft_text = whole.map(serialize_draft)

	# --- submission ----------------------------------------------------------
	# One attempt counter, one encode point: the counter is the request, and
	# `submit_request_text` is the only place it becomes a `Str` for the wire.
	task_status = Signal.from_task(submit_task)
	submit_status =
		Signal.map2(
			attempts_signal,
			task_status,
			|n, status|
				if n == 0 {
					"Not submitted yet."
				} else {
					match status {
						Loading => "Creating workspace…"
						Done(value) => "Workspace ready: ${value}"
						Failed(err) => "Submit failed: ${err}"
					}
				},
		)
	# Submitting again while a request is in flight supersedes it: the task
	# source cancels the older request and the newer one wins.
	submit_disabled = can_submit.map(|ok| !ok)

	Html.div_c(
		page_class,
		[
			Html.section_c(
				"Onboarding wizard",
				"app-header",
				[
					Html.heading_c("Onboarding Wizard", "app-title"),
					Html.paragraph_c(
						"Four steps, each with its own state handle. Validation is derived, drafts are saved to local storage, and the invite role depends on the plan you chose one step earlier.",
						"app-subtitle",
					),
				],
			),
			progress_panel({ step: h.step, summaries, label: progress_label, complete: progress_complete, attr: progress_attr }),
			Ui.when(
				step_signal.map(|current| Step.is_eq(current, Step.AccountStep)),
				|| account_panel(h.step, h.account, account_signal),
				|| Ui.when(
					step_signal.map(|current| Step.is_eq(current, Step.OrgStep)),
					|| org_panel(h.step, h.org, org_signal),
					|| Ui.when(
						step_signal.map(|current| Step.is_eq(current, Step.InvitesStep)),
						|| invites_panel(
							{
								step: h.step,
								emails: h.emails,
								role: h.role,
								org: h.org,
								emails_signal,
								role_signal,
								plan_signal,
							},
						),
						|| review_panel(h.attempts, summaries, submit_status, submit_disabled),
					),
				),
			),
			Html.section_c(
				"Wizard navigation",
				"panel flex flex-wrap items-center justify-between gap-3 p-4",
				[
					Html.div_c(
						"flex items-center gap-2",
						[
							Html.action_button_attrs(
								Signal.const("Back"),
								step_signal.map(|current| Step.is_eq(current, Step.AccountStep)),
								[Html.attr("type", "button"), Html.class_attr("button")],
								h.step.on_unit(Step.previous),
							),
							Html.button_attrs(
								"Start over",
								[Html.attr("type", "button"), Html.class_attr("button-ghost")],
								h.reset_token.on_unit(|n| n + 1),
							),
						],
					),
					Html.paragraph_s_attrs(nav_status, [Html.test_id("nav-status"), Html.class_attr(hint_class)]),
				],
			),
			# Restore a saved draft on mount. Several `Ui.on_change_initial` hooks
			# firing in the same mount pass deliver only the first command, so the
			# parsed draft lands in one inbox handle here and the per-step writes
			# fan out from there on the next propagation, where several
			# `Ui.on_change` commands do all run (see "Start over" below).
			Ui.on_change_initial(
				restored,
				|value| match value {
					Ok(_) => h.inbox.set_cmd(value)
					Err(_) => Signal.noop
				},
			),
			Ui.on_change(inbox_signal.map(|value| draft_or_empty(value).step), |value| h.step.set_cmd(value)),
			Ui.on_change(inbox_signal.map(|value| draft_or_empty(value).account), |value| h.account.set_cmd(value)),
			Ui.on_change(inbox_signal.map(|value| draft_or_empty(value).org), |value| h.org.set_cmd(value)),
			Ui.on_change(inbox_signal.map(|value| draft_or_empty(value).emails), |value| h.emails.set_cmd(value)),
			Ui.on_change(inbox_signal.map(|value| draft_or_empty(value).role), |value| h.role.set_cmd(value)),
			# Keep the saved draft in step with the form; an empty form saves nothing.
			Ui.on_change(draft_text, |text| if text == blank_draft { Browser.remove_local_storage(draft_key) } else { Browser.set_local_storage_text(draft_key, text) }),
			# The plan changed underneath the role: write the clamped value back.
			Ui.on_change(clamped_role, |value| h.role.set_cmd(value)),
			# Start over: one click, six `set_cmd` commands off one source change.
			Ui.on_change(reset_signal, |_| h.account.set_cmd(empty_account)),
			Ui.on_change(reset_signal, |_| h.org.set_cmd(empty_org)),
			Ui.on_change(reset_signal, |_| h.emails.set_cmd("")),
			Ui.on_change(reset_signal, |_| h.role.set_cmd(default_role)),
			Ui.on_change(reset_signal, |_| h.step.set_cmd(first_step)),
			Ui.on_change(reset_signal, |_| h.attempts.set_cmd(0)),
			Ui.on_change(attempts_signal, |n| if n == 0 { Signal.noop } else { Signal.start_str(submit_task, submit_request_text(n)) }),
		],
	)
}

# --- progress ----------------------------------------------------------------

## Five arguments, four of them `Signal.Signal(Str)`: named fields, so no call
## site can swap the label for the count.
ProgressView : {
	step : Ui.State(Step),
	summaries : Signal.Signal(List(StepSummary)),
	label : Signal.Signal(Str),
	complete : Signal.Signal(Str),
	attr : Signal.Signal(Str),
}

progress_panel : ProgressView -> Elem
progress_panel = |view|
	Html.section(
		"Progress",
		[Html.class_attr(panel_class), Html.attr_s("data-complete", view.attr)],
		[
			Html.div_c(
				"flex flex-wrap items-baseline justify-between gap-2",
				[
					Html.paragraph_s_attrs(view.label, [Html.test_id("progress-label"), Html.class_attr("text-base font-semibold text-zinc-950")]),
					Html.paragraph_s_attrs(view.complete, [Html.test_id("progress-complete"), Html.class_attr(hint_class)]),
				],
			),
			# The fill width is derived from the same summary fan-in that drives
			# the text, so the bar can never disagree with the count beside it.
			Html.div_c(
				"h-1.5 w-full overflow-hidden rounded-full bg-zinc-200",
				[Html.div_sc(view.summaries.map(progress_bar_class), [])],
			),
			Ui.each(view.summaries, |row| Step.slug(row.step), |each_row| summary_row(view.step, each_row.key(), each_row.signal())),
		],
	)

## Quarter-step widths, so the bar has no value the count cannot explain.
progress_bar_class : List(StepSummary) -> Str
progress_bar_class = |rows| {
	width =
		match complete_count(rows) {
			0 => "w-0"
			1 => "w-1/4"
			2 => "w-1/2"
			3 => "w-3/4"
			_ => "w-full"
		}
	"h-full rounded-full bg-emerald-500 transition-all ${width}"
}

## One progress row. The jump button is backwards-only: `Next step` is the only
## way forward, because it is the only thing that validates.
summary_row : Ui.State(Step), Str, Signal.Signal(StepSummary) -> Elem
summary_row = |step, key, row| {
	target = Step.from_slug(key)
	Html.div(
		[Html.class_attr(row_class)],
		[
			Html.div_c(
				"flex min-w-0 items-center gap-3",
				[
					Html.paragraph_s_attrs(row.map(step_badge_label), [Html.class_attr_s(row.map(step_badge_class))]),
					Html.paragraph_s_attrs(row.map(summary_line), [Html.test_id("summary-${key}"), Html.class_attr("min-w-0 text-sm text-zinc-800")]),
				],
			),
			Html.button_attrs(
				"Go to ${Step.title(target)}",
				[Html.attr("type", "button"), Html.class_attr("button button-sm shrink-0")],
				step.on_unit(|current| if Step.index(target) < Step.index(current) { target } else { current }),
			),
		],
	)
}

step_badge_label : StepSummary -> Str
step_badge_label = |value| if value.done { "Done" } else { "To do" }

## The badge colour and its caption come off the same row signal, so a row can
## never show "Done" in the neutral tone.
step_badge_class : StepSummary -> Str
step_badge_class = |value| if value.done { "badge badge-ok shrink-0" } else { "badge badge-neutral shrink-0" }

# --- step 1: account ----------------------------------------------------------

account_panel : Ui.State(Step), Ui.State(Account), Signal.Signal(Account) -> Elem
account_panel = |step, account, account_signal|
	Html.section_c(
		"Account step",
		panel_class,
		[
			Html.heading_c("Account", step_title_class),
			field(
				{
					label: "Work email",
					control: Html.text_input_attrs(
						"Work email",
						account_signal.map(|value| value.email),
						[
							Html.class_attr(input_class),
							Html.attr("placeholder", "you@company.com"),
							Html.aria_describedby("account-email-error"),
							Html.aria_invalid_s(account_signal.map(|value| value.email != "" and !valid_email(value.email))),
						],
						account.on_str(|value, text| { ..value, email: text }),
					),
					message: account_signal.map(email_message),
					tone: account_signal.map(|value| note_tone(value.email != "")),
					error_id: "account-email-error",
				},
			),
			field(
				{
					label: "Full name",
					control: Html.text_input_attrs(
						"Full name",
						account_signal.map(|value| value.full_name),
						[Html.class_attr(input_class), Html.attr("placeholder", "Ada Lovelace"), Html.aria_describedby("account-name-error")],
						account.on_str(|value, text| { ..value, full_name: text }),
					),
					message: account_signal.map(full_name_message),
					tone: account_signal.map(|value| note_tone(value.full_name != "")),
					error_id: "account-name-error",
				},
			),
			# The guard lives in the reducer: it reads `account` while writing `step`.
			next_button(step.on_unit_with(account, |current, value| if account_ok(value) { Step.OrgStep } else { current })),
		],
	)

## A labelled control with the validation note that belongs to it. Grouping
## these in one record is what keeps every form in the wizard aligned the same
## way, and it names the two `Signal.Signal(Str)`s that used to be adjacent
## positional arguments.
FieldView : {
	label : Str,
	control : Elem,
	message : Signal.Signal(Str),
	tone : Signal.Signal(Str),
	error_id : Str,
}

field : FieldView -> Elem
field = |view|
	Html.div_c(
		"field",
		[
			Html.paragraph_c(view.label, "field-label"),
			view.control,
			Html.paragraph_s_attrs(
				view.message,
				[Html.test_id(view.error_id), Html.attr("id", view.error_id), Html.class_attr_s(view.tone)],
			),
		],
	)

## Every step advances with the same control in the same place.
## The event-message type is platform-internal and has no public name, so the
## argument is spelled `_`.
next_button : _ -> Elem
next_button = |msg|
	Html.div_c(
		"flex justify-end border-t border-zinc-200 pt-4",
		[Html.button_attrs("Next step", [Html.attr("type", "button"), Html.class_attr("button-primary")], msg)],
	)

# --- step 2: organisation -----------------------------------------------------

org_panel : Ui.State(Step), Ui.State(Org), Signal.Signal(Org) -> Elem
org_panel = |step, org, org_signal| {
	# The radios are bound by their wire value, so the tag is encoded once here
	# and decoded once in the reducer below.
	region_signal = org_signal.map(|value| Region.to_str(value.region))
	pick_region = org.on_str(|value, text| { ..value, region: Region.from_str(text) })

	Html.section_c(
		"Organisation step",
		panel_class,
		[
			Html.heading_c("Organisation", step_title_class),
			field(
				{
					label: "Organisation name",
					control: Html.text_input_attrs(
						"Organisation name",
						org_signal.map(|value| value.name),
						[Html.class_attr(input_class), Html.attr("placeholder", "Analytical Engines Ltd"), Html.aria_describedby("org-name-error")],
						org.on_str(|value, text| { ..value, name: text }),
					),
					message: org_signal.map(org_name_message),
					tone: org_signal.map(|value| note_tone(value.name != "")),
					error_id: "org-name-error",
				},
			),
			Html.div_c(
				"field",
				[
					Html.paragraph_c("Plan", "field-label"),
					Html.select_c(
						"Plan",
						org_signal.map(|value| Plan.to_str(value.plan)),
						input_class,
						[
							Html.option(Plan.to_str(Plan.Starter), Plan.label(Plan.Starter)),
							Html.option(Plan.to_str(Plan.Growth), Plan.label(Plan.Growth)),
							Html.option(Plan.to_str(Plan.Enterprise), Plan.label(Plan.Enterprise)),
						],
						org.on_str(|value, text| { ..value, plan: Plan.from_str(text) }),
					),
					Html.paragraph_c("The plan decides which invite roles step 3 will offer.", hint_class),
				],
			),
			Html.div_c(
				"field",
				[
					Html.paragraph_c("Data region", "field-label"),
					Html.div(
						[Html.class_attr("grid gap-2"), Html.attr("role", "radiogroup"), Html.attr("aria-label", "Data region")],
						[
							radio_row({ label: Region.label(Region.UnitedStates), group: "region", value: Region.to_str(Region.UnitedStates), selected: region_signal, msg: pick_region }),
							radio_row({ label: Region.label(Region.EuropeanUnion), group: "region", value: Region.to_str(Region.EuropeanUnion), selected: region_signal, msg: pick_region }),
						],
					),
					Html.paragraph_s_attrs(
						org_signal.map(region_message),
						[
							Html.test_id("org-region-error"),
							Html.class_attr_s(org_signal.map(|value| note_tone(!Region.is_eq(value.region, Region.Unset)))),
						],
					),
				],
			),
			next_button(step.on_unit_with(org, |current, value| if org_ok(value) { Step.InvitesStep } else { current })),
		],
	)
}

# --- step 3: team invites -----------------------------------------------------

## Four handles and three signals: named fields, because `emails` and `role`
## were two indistinguishable `Ui.State(Str)` parameters before.
InvitesView : {
	step : Ui.State(Step),
	emails : Ui.State(Str),
	role : Ui.State(Role),
	org : Ui.State(Org),
	emails_signal : Signal.Signal(Str),
	role_signal : Signal.Signal(Role),
	plan_signal : Signal.Signal(Plan),
}

invites_panel : InvitesView -> Elem
invites_panel = |view| {
	# `on_str_with` reads the organisation's plan while writing only the role, so
	# a role the plan does not include can never be stored. The radio's wire
	# value is decoded here, at the one place it arrives as text.
	pick_role =
		view.role.on_str_with(
			view.org,
			|current, org_value, text| {
				picked = Role.from_str(text)
				if plan_includes(org_value.plan, picked) { picked } else { current }
			},
		)
	selected_role = view.role_signal.map(Role.to_str)

	Html.section_c(
		"Team invites step",
		panel_class,
		[
			Html.heading_c("Team invites", step_title_class),
			field(
				{
					label: "Invite emails",
					control: Html.textarea_attrs(
						"Invite emails",
						view.emails_signal,
						[Html.class_attr(textarea_class), Html.attr("placeholder", "One address per line"), Html.aria_describedby("invite-emails-error")],
						view.emails.on_str(|_current, text| text),
					),
					message: view.emails_signal.map(invite_message),
					tone: view.emails_signal.map(|value| note_tone(value != "")),
					error_id: "invite-emails-error",
				},
			),
			Html.div_c(
				"field",
				[
					Html.paragraph_c("Default role", "field-label"),
					Html.div(
						[Html.class_attr("grid gap-2"), Html.attr("role", "radiogroup"), Html.attr("aria-label", "Default role")],
						[
							role_radio(Role.Member, selected_role, pick_role),
							# The plan gates these two, so the option list itself is
							# derived rather than merely disabled.
							Ui.when(
								view.plan_signal.map(|plan| plan_includes(plan, Role.Admin)),
								|| role_radio(Role.Admin, selected_role, pick_role),
								|| Html.text(""),
							),
							Ui.when(
								view.plan_signal.map(|plan| plan_includes(plan, Role.Billing)),
								|| role_radio(Role.Billing, selected_role, pick_role),
								|| Html.text(""),
							),
						],
					),
					Html.paragraph_s_attrs(Signal.map2(view.plan_signal, view.role_signal, role_message), [Html.test_id("invite-role-note"), Html.class_attr(hint_class)]),
				],
			),
			next_button(view.step.on_unit_with(view.emails, |current, value| if invites_ok(value) { Step.ReviewStep } else { current })),
		],
	)
}

# --- step 4: review -----------------------------------------------------------

review_panel : Ui.State(U64), Signal.Signal(List(StepSummary)), Signal.Signal(Str), Signal.Signal(Bool) -> Elem
review_panel = |attempts, summaries, submit_status, submit_disabled|
	Html.section_c(
		"Review step",
		panel_class,
		[
			Html.heading_c("Review", step_title_class),
			Html.div_c(
				"grid gap-2",
				[
					review_row("Account", summaries.map(|rows| summary_at(rows, 0)), "review-account"),
					review_row("Organisation", summaries.map(|rows| summary_at(rows, 1)), "review-organisation"),
					review_row("Team invites", summaries.map(|rows| summary_at(rows, 2)), "review-invites"),
				],
			),
			Html.div_c(
				"flex flex-wrap items-center justify-between gap-3 border-t border-zinc-200 pt-4",
				[
					Html.paragraph_s_attrs(submit_status, [Html.test_id("submit-status"), Html.class_attr(note_class)]),
					Html.action_button_attrs(
						Signal.const("Create workspace"),
						submit_disabled,
						[Html.attr("type", "button"), Html.class_attr("button-primary")],
						attempts.on_unit(|n| n + 1),
					),
				],
			),
		],
	)

review_row : Str, Signal.Signal(Str), Str -> Elem
review_row = |label, line, id|
	Html.div_c(
		"grid gap-0.5 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2",
		[
			Html.paragraph_c(label, "field-label"),
			Html.paragraph_s_attrs(line, [Html.test_id(id), Html.class_attr("text-sm text-zinc-800")]),
		],
	)

## The fan-in always produces four rows, so the fallback is unreachable; it is
## spelled out rather than left to a crash.
summary_at : List(StepSummary), U64 -> Str
summary_at = |rows, index|
	rows.get(index).map_ok(summary_line) ?? "Missing: no data (incomplete)"

## An index past the end of the rows renders the placeholder instead of crashing.
expect summary_at([], 0) == "Missing: no data (incomplete)"

## Radios are bare inputs, so the visible caption is drawn next to them here.
## The event-message type is platform-internal and has no public name, so the
## `msg` field is spelled `_`.
radio_row : { label : Str, group : Str, value : Str, selected : Signal.Signal(Str), msg : _ } -> Elem
radio_row = |view|
	Html.div_c(
		"check-row",
		[
			Html.radio_c(view.label, view.group, view.value, view.selected, "checkbox", view.msg),
			Html.text(view.label),
		],
	)

## One invite-role radio. The caption and the wire value both come off the tag,
## so they cannot drift apart.
role_radio : Role, Signal.Signal(Str), _ -> Elem
role_radio = |role, selected, msg|
	radio_row({ label: Role.label(role), group: "invite-role", value: Role.to_str(role), selected, msg })
