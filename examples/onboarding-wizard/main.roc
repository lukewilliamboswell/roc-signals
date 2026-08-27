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
##
## The signal graph:
##
##     account ──> account_valid ─┐
##     org ──────> org_valid ─────┼─> can_submit ──> submit_disabled
##     emails ───> invites_valid ─┘        │
##                                         └─> progress_complete
##
##     account ──> account_summary ─┐
##     org ──────> org_summary ─────┼─> Signal.combine ──> summaries ──> each_str
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

Account : { email : Str, full_name : Str }
Org : { name : Str, plan : Str, region : Str }
StepSummary : { key : Str, title : Str, detail : Str, done : Bool }

empty_account : Account
empty_account = { email: "", full_name: "" }

empty_org : Org
empty_org = { name: "", plan: "starter", region: "" }

default_role : Str
default_role = "member"

first_step : U64
first_step = 0

contains_text : Str, Str -> Bool
contains_text = |haystack, needle| haystack.split_on(needle).len() > 1

valid_email : Str -> Bool
valid_email = |raw| {
	text = raw.trim()
	parts = text.split_on("@")
	match parts.get(1) {
		Ok(domain) => (parts.len() == 2) and (!text.starts_with("@")) and contains_text(domain, ".") and (!domain.starts_with(".")) and (!domain.ends_with("."))
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

account_ok : Account -> Bool
account_ok = |value| valid_email(value.email) and (!value.full_name.trim().is_empty())

org_ok : Org -> Bool
org_ok = |value| (!value.name.trim().is_empty()) and (!value.region.is_empty())

invites_ok : Str -> Bool
invites_ok = |raw| bad_invites(raw).is_empty()

## Which invite roles a plan includes. Starter is a single-role plan, which is
## what makes the cross-step dependency observable.
role_allowed : Str, Str -> Bool
role_allowed = |plan, role|
	if role == "member" {
		True
	} else if role == "admin" {
		plan != "starter"
	} else if role == "billing" {
		plan == "enterprise"
	} else {
		False
	}

plan_label : Str -> Str
plan_label = |plan|
	if plan == "growth" {
		"Growth"
	} else if plan == "enterprise" {
		"Enterprise"
	} else {
		"Starter"
	}

region_label : Str -> Str
region_label = |region|
	if region == "us" {
		"United States"
	} else if region == "eu" {
		"European Union"
	} else {
		"not chosen"
	}

role_label : Str -> Str
role_label = |role|
	if role == "admin" {
		"Admin"
	} else if role == "billing" {
		"Billing admin"
	} else {
		"Member"
	}

step_slug : U64 -> Str
step_slug = |index|
	if index == 1 {
		"organisation"
	} else if index == 2 {
		"invites"
	} else if index == 3 {
		"review"
	} else {
		"account"
	}

step_index : Str -> U64
step_index = |slug|
	if slug == "organisation" {
		1
	} else if slug == "invites" {
		2
	} else if slug == "review" {
		3
	} else {
		0
	}

step_title : U64 -> Str
step_title = |index|
	if index == 1 {
		"Organisation"
	} else if index == 2 {
		"Team invites"
	} else if index == 3 {
		"Review"
	} else {
		"Account"
	}

# --- draft serialization -----------------------------------------------------

Draft : { account : Account, org : Org, emails : Str, role : Str, step : U64 }

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
			value.org.plan,
			value.org.region,
			safe_field(value.emails),
			value.role,
			step_slug(value.step),
		],
		"|",
	)

field_at : List(Str), U64 -> Str
field_at = |parts, index|
	match parts.get(index) {
		Ok(value) => value
		Err(_) => ""
	}

blank_draft : Str
blank_draft = serialize_draft({ account: empty_account, org: empty_org, emails: "", role: default_role, step: first_step })

## A draft with the wrong shape is ignored rather than half-applied.
ParsedDraft : { ok : Bool, draft : Draft }

empty_draft : Draft
empty_draft = { account: empty_account, org: empty_org, emails: "", role: default_role, step: first_step }

no_draft : ParsedDraft
no_draft = { ok: False, draft: empty_draft }

parse_draft : Str -> ParsedDraft
parse_draft = |text| {
	parts = text.split_on("|")
	if parts.len() != 8 {
		{ ok: False, draft: empty_draft }
	} else {
		plan = field_at(parts, 3)
		role = field_at(parts, 6)
		{
			ok: True,
			draft: {
				account: { email: field_at(parts, 0), full_name: field_at(parts, 1) },
				org: { name: field_at(parts, 2), plan, region: field_at(parts, 4) },
				emails: field_at(parts, 5),
				role: if role_allowed(plan, role) { role } else { default_role },
				step: step_index(field_at(parts, 7)),
			},
		}
	}
}

## A missing, unavailable, or corrupt value parses to `ok: False`, so the empty
## form is left alone rather than half-populated.
read_draft : Browser.StorageText -> ParsedDraft
read_draft = |stored|
	match stored {
		StorageValue(text) => parse_draft(text)
		StorageMissing => { ok: False, draft: empty_draft }
		StorageUnavailable(_) => { ok: False, draft: empty_draft }
	}

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
	if value.region.is_empty() {
		"Choose a data region."
	} else {
		"Data stored in ${region_label(value.region)}."
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

role_message : Str, Str -> Str
role_message = |plan, role|
	if plan == "starter" {
		"Starter plans have one role. Upgrade to invite admins."
	} else if plan == "growth" {
		"Growth plans include Member and Admin."
	} else {
		"Enterprise plans include Member, Admin and Billing admin. Current: ${role_label(role)}."
	}

# --- summaries ---------------------------------------------------------------

account_summary_of : Account -> StepSummary
account_summary_of = |value| {
	key: "account",
	title: "Account",
	detail: if value.email.trim().is_empty() { "No email yet" } else { "${value.email.trim()} / ${value.full_name.trim()}" },
	done: account_ok(value),
}

org_summary_of : Org -> StepSummary
org_summary_of = |value| {
	key: "organisation",
	title: "Organisation",
	detail: if value.name.trim().is_empty() { "No organisation yet" } else { "${value.name.trim()} on ${plan_label(value.plan)} in ${region_label(value.region)}" },
	done: org_ok(value),
}

invites_summary_of : Str, Str -> StepSummary
invites_summary_of = |raw, role| {
	key: "invites",
	title: "Team invites",
	detail: "${invite_list(raw).len().to_str()} invite(s) as ${role_label(role)}",
	done: invites_ok(raw),
}

review_summary_of : Bool -> StepSummary
review_summary_of = |ready| {
	key: "review",
	title: "Review",
	detail: if ready { "Ready to create the workspace" } else { "Finish the earlier steps first" },
	done: ready,
}

summary_line : StepSummary -> Str
summary_line = |value| "${value.title}: ${value.detail} (${if value.done { "complete" } else { "incomplete" }})"

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
## touched, and only turns red once there is input that cannot be accepted.
note_tone : Str, Bool -> Str
note_tone = |text, touched|
	if text == "" {
		"hidden"
	} else if touched {
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
	step : Ui.State(U64),
	account : Ui.State(Account),
	org : Ui.State(Org),
	emails : Ui.State(Str),
	role : Ui.State(Str),
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

	progress_label = step_signal.map(|index| "Step ${(index + 1).to_str()} of 4 — ${step_title(index)}")
	progress_complete = summaries.map(|rows| "${complete_count(rows).to_str()} of 4 steps complete")
	progress_attr = summaries.map(|rows| complete_count(rows).to_str())

	step_valid =
		Signal.map2(
			step_signal,
			Signal.combine([account_valid, org_valid, invites_valid, can_submit]),
			|index, flags| match flags.get(index) {
				Ok(flag) => flag
				Err(_) => False
			},
		)
	nav_status =
		Signal.map2(
			step_signal,
			step_valid,
			|index, ok|
				if index == 3 {
					if ok { "Everything checks out. Create the workspace." } else { "Go back and finish the incomplete steps." }
				} else if ok {
					"Ready for the next step."
				} else {
					"Complete this step to continue."
				},
		)

	# --- the plan clamps the invite role. Reset, not hide: the value the user
	# --- sees is the value that is saved and submitted.
	clamped_role = Signal.map2(role_signal, plan_signal, |current, plan| if role_allowed(plan, current) { current } else { default_role })

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
	submit_request = attempts_signal.map(|n| if n == 0 { "" } else { "submit-${n.to_str()}" })
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
			progress_panel(h.step, summaries, progress_label, progress_complete, progress_attr),
			Ui.when(
				step_signal.map(|index| index == 0),
				|| account_panel(h.step, h.account, account_signal),
				|| Ui.when(
					step_signal.map(|index| index == 1),
					|| org_panel(h.step, h.org, org_signal),
					|| Ui.when(
						step_signal.map(|index| index == 2),
						|| invites_panel(h.step, h.emails, h.role, h.org, emails_signal, role_signal, plan_signal),
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
								step_signal.map(|index| index == 0),
								[Html.attr("type", "button"), Html.class_attr("button")],
								h.step.on_unit(|index| if index == 0 { 0 } else { index - 1 }),
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
			Ui.on_change_initial(restored, |value| if value.ok { h.inbox.set_cmd(value) } else { Signal.noop }),
			Ui.on_change(inbox_signal.map(|value| value.draft.step), |value| h.step.set_cmd(value)),
			Ui.on_change(inbox_signal.map(|value| value.draft.account), |value| h.account.set_cmd(value)),
			Ui.on_change(inbox_signal.map(|value| value.draft.org), |value| h.org.set_cmd(value)),
			Ui.on_change(inbox_signal.map(|value| value.draft.emails), |value| h.emails.set_cmd(value)),
			Ui.on_change(inbox_signal.map(|value| value.draft.role), |value| h.role.set_cmd(value)),
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
			Ui.on_change(submit_request, |request| if request == "" { Signal.noop } else { Signal.start_str(submit_task, request) }),
		],
	)
}

# --- progress ----------------------------------------------------------------

progress_panel : Ui.State(U64), Signal.Signal(List(StepSummary)), Signal.Signal(Str), Signal.Signal(Str), Signal.Signal(Str) -> Elem
progress_panel = |step, summaries, label, complete, attr|
	Html.section(
		"Progress",
		[Html.class_attr(panel_class), Html.attr_s("data-complete", attr)],
		[
			Html.div_c(
				"flex flex-wrap items-baseline justify-between gap-2",
				[
					Html.paragraph_s_attrs(label, [Html.test_id("progress-label"), Html.class_attr("text-base font-semibold text-zinc-950")]),
					Html.paragraph_s_attrs(complete, [Html.test_id("progress-complete"), Html.class_attr(hint_class)]),
				],
			),
			# The fill width is derived from the same summary fan-in that drives
			# the text, so the bar can never disagree with the count beside it.
			Html.div_c(
				"h-1.5 w-full overflow-hidden rounded-full bg-zinc-200",
				[Html.div_sc(summaries.map(progress_bar_class), [])],
			),
			Ui.each_str(summaries, |row| row.key, |key, row| summary_row(step, key, row)),
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
summary_row : Ui.State(U64), Str, Signal.Signal(StepSummary) -> Elem
summary_row = |step, key, row| {
	target = step_index(key)
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
				"Go to ${step_title(target)}",
				[Html.attr("type", "button"), Html.class_attr("button button-sm shrink-0")],
				step.on_unit(|current| if target < current { target } else { current }),
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

account_panel : Ui.State(U64), Ui.State(Account), Signal.Signal(Account) -> Elem
account_panel = |step, account, account_signal|
	Html.section_c(
		"Account step",
		panel_class,
		[
			Html.heading_c("Account", step_title_class),
			field(
				"Work email",
				Html.text_input_attrs(
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
				account_signal.map(email_message),
				account_signal.map(|value| note_tone(email_message(value), value.email != "")),
				"account-email-error",
			),
			field(
				"Full name",
				Html.text_input_attrs(
					"Full name",
					account_signal.map(|value| value.full_name),
					[Html.class_attr(input_class), Html.attr("placeholder", "Ada Lovelace"), Html.aria_describedby("account-name-error")],
					account.on_str(|value, text| { ..value, full_name: text }),
				),
				account_signal.map(full_name_message),
				account_signal.map(|value| note_tone(full_name_message(value), value.full_name != "")),
				"account-name-error",
			),
			# The guard lives in the reducer: it reads `account` while writing `step`.
			next_button(step.on_unit_with(account, |current, value| if account_ok(value) { 1 } else { current })),
		],
	)

## A labelled control with the validation note that belongs to it. Grouping
## these three here is what keeps every form in the wizard aligned the same way.
field : Str, Elem, Signal.Signal(Str), Signal.Signal(Str), Str -> Elem
field = |label, control, message, tone, error_id|
	Html.div_c(
		"field",
		[
			Html.paragraph_c(label, "field-label"),
			control,
			Html.paragraph_s_attrs(
				message,
				[Html.test_id(error_id), Html.attr("id", error_id), Html.class_attr_s(tone)],
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

org_panel : Ui.State(U64), Ui.State(Org), Signal.Signal(Org) -> Elem
org_panel = |step, org, org_signal| {
	region_signal = org_signal.map(|value| value.region)

	Html.section_c(
		"Organisation step",
		panel_class,
		[
			Html.heading_c("Organisation", step_title_class),
			field(
				"Organisation name",
				Html.text_input_attrs(
					"Organisation name",
					org_signal.map(|value| value.name),
					[Html.class_attr(input_class), Html.attr("placeholder", "Analytical Engines Ltd"), Html.aria_describedby("org-name-error")],
					org.on_str(|value, text| { ..value, name: text }),
				),
				org_signal.map(org_name_message),
				org_signal.map(|value| note_tone(org_name_message(value), value.name != "")),
				"org-name-error",
			),
			Html.div_c(
				"field",
				[
					Html.paragraph_c("Plan", "field-label"),
					Html.select_c(
						"Plan",
						org_signal.map(|value| value.plan),
						input_class,
						[
							Html.option("starter", "Starter"),
							Html.option("growth", "Growth"),
							Html.option("enterprise", "Enterprise"),
						],
						org.on_str(|value, text| { ..value, plan: text }),
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
							radio_row("United States", "region", "us", region_signal, org.on_str(|value, text| { ..value, region: text })),
							radio_row("European Union", "region", "eu", region_signal, org.on_str(|value, text| { ..value, region: text })),
						],
					),
					Html.paragraph_s_attrs(
						org_signal.map(region_message),
						[
							Html.test_id("org-region-error"),
							Html.class_attr_s(org_signal.map(|value| note_tone(region_message(value), value.region != ""))),
						],
					),
				],
			),
			next_button(step.on_unit_with(org, |current, value| if org_ok(value) { 2 } else { current })),
		],
	)
}

# --- step 3: team invites -----------------------------------------------------

invites_panel : Ui.State(U64), Ui.State(Str), Ui.State(Str), Ui.State(Org), Signal.Signal(Str), Signal.Signal(Str), Signal.Signal(Str) -> Elem
invites_panel = |step, emails, role, org, emails_signal, role_signal, plan_signal| {
	# `on_str_with` reads the organisation's plan while writing only the role, so
	# a role the plan does not include can never be stored.
	pick_role = role.on_str_with(org, |current, org_value, text| if role_allowed(org_value.plan, text) { text } else { current })

	Html.section_c(
		"Team invites step",
		panel_class,
		[
			Html.heading_c("Team invites", step_title_class),
			field(
				"Invite emails",
				Html.textarea_attrs(
					"Invite emails",
					emails_signal,
					[Html.class_attr(textarea_class), Html.attr("placeholder", "One address per line"), Html.aria_describedby("invite-emails-error")],
					emails.on_str(|_current, text| text),
				),
				emails_signal.map(invite_message),
				emails_signal.map(|value| note_tone(invite_message(value), value != "")),
				"invite-emails-error",
			),
			Html.div_c(
				"field",
				[
					Html.paragraph_c("Default role", "field-label"),
					Html.div(
						[Html.class_attr("grid gap-2"), Html.attr("role", "radiogroup"), Html.attr("aria-label", "Default role")],
						[
							radio_row("Member", "invite-role", "member", role_signal, pick_role),
							# The plan gates these two, so the option list itself is
							# derived rather than merely disabled.
							Ui.when(
								plan_signal.map(|plan| role_allowed(plan, "admin")),
								|| radio_row("Admin", "invite-role", "admin", role_signal, pick_role),
								|| Html.text(""),
							),
							Ui.when(
								plan_signal.map(|plan| role_allowed(plan, "billing")),
								|| radio_row("Billing admin", "invite-role", "billing", role_signal, pick_role),
								|| Html.text(""),
							),
						],
					),
					Html.paragraph_s_attrs(Signal.map2(plan_signal, role_signal, role_message), [Html.test_id("invite-role-note"), Html.class_attr(hint_class)]),
				],
			),
			next_button(step.on_unit_with(emails, |current, value| if invites_ok(value) { 3 } else { current })),
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
					review_row("Account", summaries.map(|rows| summary_line(row_at(rows, 0))), "review-account"),
					review_row("Organisation", summaries.map(|rows| summary_line(row_at(rows, 1))), "review-organisation"),
					review_row("Team invites", summaries.map(|rows| summary_line(row_at(rows, 2))), "review-invites"),
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

row_at : List(StepSummary), U64 -> StepSummary
row_at = |rows, index|
	match rows.get(index) {
		Ok(row) => row
		Err(_) => { key: "missing", title: "Missing", detail: "no data", done: False }
	}

## Radios are bare inputs, so the visible caption is drawn next to them here.
radio_row : Str, Str, Str, Signal.Signal(Str), _ -> Elem
radio_row = |label, group, value, selected, msg|
	Html.div_c(
		"check-row",
		[
			Html.radio_c(label, group, value, selected, "checkbox", msg),
			Html.text(label),
		],
	)
