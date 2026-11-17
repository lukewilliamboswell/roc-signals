import pf.Base64
import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.WebCrypto

## The fixture uses 1,000 PBKDF2 iterations to keep repeated spec and soak runs
## inexpensive. This is a test cost, not a password-storage recommendation.
CryptoApp := [].{
	Action : [Random(U64), Batch33, EmptyHash, Hash(WebCrypto.Hash), Derive([Sha256, Sha512]), Seal, SealAndLock, Open([Correct, ChangedAssociated, ChangedCiphertext, InvalidIv]), InvalidSalt, InvalidIterations, ExcessiveIterations]
	Answer : [Random(List(U8)), Hashed(List(U8)), Derived(WebCrypto.Key), Sealed(WebCrypto.Sealed), Opened(List(U8)), LockNow]
	S : {
		password : Str,
		plaintext : Str,
		salt : List(U8),
		key : [Locked, Unlocked(WebCrypto.Key)],
		envelope : [Empty, Sealed(WebCrypto.Sealed)],
		posts : Engine.Outbox(Action),
		notice : Str,
		opened : Str,
		fresh_iv : Bool,
		panel : Bool,
		latest : [Idle, Run(U64)],
	}

	initial : S
	initial = {
		password: "correct horse",
		plaintext: "secret λ",
		salt: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
		key: Locked,
		envelope: Empty,
		posts: Engine.outbox({}),
		notice: "idle",
		opened: "",
		fresh_iv: False,
		panel: False,
		latest: Idle,
	}

	post : S, Action -> S
	post = |s, action| { ..s, posts: s.posts.post(action), notice: "pending" }

	plan : S, Action -> List(Engine.Ask(Answer, WebCrypto.Error))
	plan = |s, action| match action {
		Random(count) => [WebCrypto.random_bytes(count).map_ok(|value| Random(value))]
		Batch33 => List.repeat(WebCrypto.random_bytes(1).map_ok(|value| Random(value)), 33)
		EmptyHash => [WebCrypto.digest(Sha512, []).map_ok(|value| Hashed(value))]
		Hash(hash) => [WebCrypto.digest(hash, "abc".to_utf8()).map_ok(|value| Hashed(value))]
		Derive(hash) => [WebCrypto.derive_key({ password: s.password, salt: s.salt, iterations: 1000, hash }).map_ok(|value| Derived(value))]
		InvalidSalt => [WebCrypto.derive_key({ password: s.password, salt: [], iterations: 1000 }).map_ok(|value| Derived(value))]
		InvalidIterations => [WebCrypto.derive_key({ password: s.password, salt: s.salt, iterations: 0 }).map_ok(|value| Derived(value))]
		ExcessiveIterations => [WebCrypto.derive_key({ password: s.password, salt: s.salt, iterations: 1001 }).map_ok(|value| Derived(value))]
		Seal | SealAndLock => match s.key {
			Locked => []
			Unlocked(key) => {
				asks = [WebCrypto.encrypt(key, { plaintext: s.plaintext.to_utf8(), associated: "project:7".to_utf8() }).map_ok(|value| Sealed(value))]
				# The follow-up locks before this host call returns. The batch still
				# names the key, so the executor must resolve it before draining releases.
				if (action == SealAndLock) asks.append(Engine.again({}).map_ok(|_| LockNow)) else asks
			}
		}
		Open(mode) => match (s.key, s.envelope) {
			(Unlocked(key), Sealed(envelope)) => {
				ciphertext = if (mode == ChangedCiphertext) CryptoApp.tamper(envelope.ciphertext) else envelope.ciphertext
				associated = if (mode == ChangedAssociated) "project:8" else "project:7"
				iv = if (mode == InvalidIv) [] else envelope.iv
				[WebCrypto.decrypt(key, { iv, ciphertext, associated: associated.to_utf8() }).map_ok(|value| Opened(value))]
			}
			_ => []
		}
	}

	tamper : List(U8) -> List(U8)
	tamper = |bytes| match bytes {
		[first, .. as rest] => [first.bitwise_xor(1)].concat(rest)
		[] => []
	}

	answered : S, Action, Try(Answer, WebCrypto.Error) -> S
	answered = |s, _action, result| match result {
		Err(error) => { ..s, notice: "failed ${Str.inspect(error)}", opened: "" }
		Ok(Random(bytes)) => { ..s, notice: "random ${bytes.len().to_str()}", salt: if (bytes.len() == 16) bytes else s.salt }
		Ok(Hashed(bytes)) => { ..s, notice: "digest ${Base64.encode(bytes)}" }
		Ok(Derived(key)) => { ..s, key: Unlocked(key), notice: "unlocked" }
		Ok(Sealed(envelope)) => {
			fresh_iv = match s.envelope {
				Empty => False
				Sealed(previous) => previous.iv != envelope.iv
			}
			{ ..s, envelope: Sealed(envelope), fresh_iv, notice: "sealed iv=${envelope.iv.len().to_str()} bytes=${envelope.ciphertext.len().to_str()}" }
		}
		Ok(Opened(bytes)) => {
			text = Str.from_utf8(bytes) ?? crash "CryptoApp: authenticated fixture text must be UTF-8"
			{ ..s, notice: "opened", opened: text }
		}
		Ok(LockNow) => { ..s, key: Locked }
	}

	control : State(ctx, S), { label : Str, action : Action } -> Elem(ctx)
	control = |state, { label, action }| Html.button(label, [], state.update(|s| CryptoApp.post(s, action)))

	view : State(In(Root, S), S) -> Elem(In(Root, S))
	view = |state| {
		reading = state.signal()
		Html.div(
			"",
			[
				Html.text_input(Engine.const("Password"), "password", reading.map(|s| s.password), [], state.set_value(|s, password| { ..s, password })),
				Html.text_input(Engine.const("Plaintext"), "text", reading.map(|s| s.plaintext), [], state.set_value(|s, plaintext| { ..s, plaintext })),
				CryptoApp.control(state, { label: "Random zero", action: Random(0) }),
				CryptoApp.control(state, { label: "Random batch 33", action: Batch33 }),
				CryptoApp.control(state, { label: "Empty SHA-512", action: EmptyHash }),
				CryptoApp.control(state, { label: "New salt", action: Random(16) }),
				CryptoApp.control(state, { label: "Random large", action: Random(1024) }),
				CryptoApp.control(state, { label: "SHA-256", action: Hash(Sha256) }),
				CryptoApp.control(state, { label: "SHA-384", action: Hash(Sha384) }),
				CryptoApp.control(state, { label: "SHA-512", action: Hash(Sha512) }),
				CryptoApp.control(state, { label: "Unlock SHA-256", action: Derive(Sha256) }),
				CryptoApp.control(state, { label: "Unlock SHA-512", action: Derive(Sha512) }),
				CryptoApp.control(state, { label: "Seal", action: Seal }),
				CryptoApp.control(state, { label: "Seal and lock", action: SealAndLock }),
				CryptoApp.control(state, { label: "Open", action: Open(Correct) }),
				CryptoApp.control(state, { label: "Wrong associated data", action: Open(ChangedAssociated) }),
				CryptoApp.control(state, { label: "Tampered ciphertext", action: Open(ChangedCiphertext) }),
				CryptoApp.control(state, { label: "Invalid IV", action: Open(InvalidIv) }),
				CryptoApp.control(state, { label: "Invalid salt", action: InvalidSalt }),
				CryptoApp.control(state, { label: "Zero iterations", action: InvalidIterations }),
				CryptoApp.control(state, { label: "Too many iterations", action: ExcessiveIterations }),
				Html.button("Lock", [], state.update(|s| { ..s, key: Locked, opened: "", notice: "locked" })),
				Html.button("Reset", [], state.update(|_| CryptoApp.initial)),
				Html.p_s(reading.map(|s| s.notice), [Engine.test_id("result")]),
				Html.p_s(reading.map(|s| s.opened), [Engine.test_id("plaintext")]),
				Html.p_s(
					reading.map(
						|s| match s.key {
							Locked => "locked"
							Unlocked(_) => "unlocked"
						},
					),
					[Engine.test_id("key")],
				),
				Html.p_s(reading.map(|s| Str.inspect(s.fresh_iv)), [Engine.test_id("fresh-iv")]),
				Engine.on_post_by(reading.map(|s| s.posts), reading, CryptoApp.plan, state.on_result(CryptoApp.answered)),
				Html.button("Panel", [], state.update(|s| { ..s, panel: !s.panel })),
				Engine.when(
					reading.map(|s| s.panel),
					|| Engine.resource(
						Engine.const({}),
						{
							init: Waiting,
							pending: |_, _| Waiting,
							plan: |_| [WebCrypto.derive_key({ password: "panel password", salt: CryptoApp.initial.salt, iterations: 1000 })],
							resolve: |_, _, result| match result {
								Ok(key) => Ready(key)
								Err(error) => Failed(error)
							},
						},
						|status| Html.p_s(
							status.map(
								|value| match value {
									Waiting => "waiting"
									Ready(_) => "derived"
									Failed(error) => Str.inspect(error)
								},
							),
							[Engine.test_id("panel")],
						),
					),
					|| Engine.text(""),
				),
				Html.button("Latest 16", [], state.update(|s| { ..s, latest: Run(16) })),
				Html.button("Latest 17", [], state.update(|s| { ..s, latest: Run(17) })),
				Html.button("Cancel latest", [], state.update(|s| { ..s, latest: Idle })),
				Engine.resource(
					reading.map(|s| s.latest),
					{
						init: "idle",
						pending: |_, latest| if (latest == Idle) "idle" else "waiting",
						plan: |latest| match latest {
							Idle => []
							Run(count) => [WebCrypto.random_bytes(count)]
						},
						resolve: |_, _, result| match result {
							Ok(bytes) => "random ${bytes.len().to_str()}"
							Err(error) => "failed ${Str.inspect(error)}"
						},
					},
					|status| Html.p_s(status, [Engine.test_id("latest")]),
				),
			],
		)
	}
}
