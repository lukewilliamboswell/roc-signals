import PictureBoot
import PictureCapture
import PictureCodec
import PictureHash
import PicturePlan

## Roc judges the measured facts against its own ordinary mount. The browser
## supplies measurements; it never substitutes a verdict after this decision.
PictureVerdict :: [].{

	Limits := { codec : PictureCodec.Limits ?? {}, max_measurement_bytes : U64 ?? 67108864 }
	Reason : [NoPicture, MalformedPicture, DifferentRoot, DifferentMount, DifferentMeasurement, CaptureUnavailable, DifferentClaims, MeasurementLimit]
	Decision :: [Replace(Reason), Adopt(PicturePlan.Plan)]
	Props : { picture : PictureBoot.Input, root_name : PictureCodec.Name, batch : List(U8), capture : Try(List(PictureCapture.Frame), [NotCaptured, CaptureLimit, InvalidBoundary]), next : U32, free : List(U32) }

	## Absence and mismatches select replacement before any physical mutation.
	## Bad deployment bounds are caller errors, distinct from picture facts.
	decide : Props, Limits -> Try(Decision, [InvalidLimits])
	decide = |props, limits| {
		if limits.codec.max_bytes > 16777179 or limits.codec.max_nodes > 262144 or limits.codec.max_depth > 1024 or limits.max_measurement_bytes > 67108864 {
			return Err(InvalidLimits)
		}
		facts = match PictureBoot.parts(props.picture) {
			Absent => return Ok(Replace(NoPicture))
			Present(value) => value
		}
		envelope = match PictureCodec.read(facts.envelope, limits.codec) {
			Ok(value) => value
			Err(_) => return Ok(Replace(MalformedPicture))
		}
		parts = PictureCodec.parts(envelope)
		if parts.root_name != props.root_name {
			return Ok(Replace(DifferentRoot))
		}
		if parts.batch_bytes.to_u64() != props.batch.len() {
			return Ok(Replace(DifferentMount))
		}
		domain = "roc-signals/mount/19/1".to_utf8()
		required = domain.len() + 1 + 4 + props.batch.len()
		if required > limits.max_measurement_bytes or props.batch.len() > 4294967295 {
			return Ok(Replace(MeasurementLimit))
		}
		var $framed = List.with_capacity(required).concat(domain).append(0)
		count = props.batch.len().to_u32_wrap()
		for shift in [0.U8, 8, 16, 24] {
			$framed = $framed.append(count.shr_wrap(shift).to_u8_wrap())
		}
		fingerprint = PictureHash.digest($framed.concat(props.batch))
		if parts.fingerprint != fingerprint {
			return Ok(Replace(DifferentMount))
		}
		if facts.measured != parts.expected {
			return Ok(Replace(DifferentMeasurement))
		}
		frames = match props.capture {
			Ok(value) => value
			Err(_) => return Ok(Replace(CaptureUnavailable))
		}
		match PicturePlan.build({ batch: props.batch, frames, next: props.next, free: props.free, envelope }) {
			Ok(plan) => Ok(Adopt(plan))
			Err(_) => Ok(Replace(DifferentClaims))
		}
	}

	## The command encoder consumes the accepted plan or explicit replacement
	## reason; no adapter is allowed to change an Adopt into a replacement.
	parts : Decision -> [Replace(Reason), Adopt(PicturePlan.Plan)]
	parts = |decision| match decision {
		Replace(reason) => Replace(reason)
		Adopt(plan) => Adopt(plan)
	}
}

## An independently computed SHA-256 pins the empty ordinary batch domain.
## All matching facts adopt; no node, application state or browser is needed.
expect {
	fixture = empty_fixture({})?
	decision = PictureVerdict.decide(fixture, {})?
	match PictureVerdict.parts(decision) {
		Adopt(plan) => PicturePlan.operations(plan).is_empty()
		Replace(_) => False
	}
}

## A valid digest mismatch is a replacement verdict, not malformed metadata.
## A root tuple mismatch and stale mount bytes also replace before claims run.
expect {
	fixture = empty_fixture({})?
	facts = match PictureBoot.parts(fixture.picture) {
		Present(value) => value
		Absent => crash "empty fixture supplies a picture"
	}
	changed = PictureBoot.present({ ..facts, measured: List.repeat(8, 32) })?
	cases = [
		{ props: { ..fixture, picture: PictureBoot.absent }, reason: NoPicture },
		{ props: { ..fixture, root_name: { ..fixture.root_name, prefix: "p" } }, reason: DifferentRoot },
		{ props: { ..fixture, batch: [0] }, reason: DifferentMount },
		{ props: { ..fixture, picture: changed }, reason: DifferentMeasurement },
		{ props: { ..fixture, capture: Err(CaptureLimit) }, reason: CaptureUnavailable },
		{ props: { ..fixture, capture: Ok([{ at: 1, end: 2, opcode: 10, address: 1, slot: 0, kind: 0 }]) }, reason: DifferentClaims },
	]
	cases.all(
		|case| match PictureVerdict.parts(PictureVerdict.decide(case.props, {}) ?? crash "valid verdict limits") {
			Replace(reason) => reason == case.reason
			Adopt(_) => False
		},
	)
}

## Measurement refusal is inclusive and happens before hashing. Invalid
## limits cannot silently masquerade as an absent picture.
expect {
	fixture = empty_fixture({})?
	minimum = "roc-signals/mount/19/1".count_utf8_bytes() + 5
	at_limit = PictureVerdict.decide(fixture, { max_measurement_bytes: minimum })?
	over_limit = PictureVerdict.decide(fixture, { max_measurement_bytes: minimum - 1 })?
	adopted = match PictureVerdict.parts(at_limit) {
		Adopt(_) => True
		Replace(_) => False
	}
	refused = match PictureVerdict.parts(over_limit) {
		Replace(MeasurementLimit) => True
		_ => False
	}
	adopted and refused and PictureVerdict.decide({ ..fixture, picture: PictureBoot.absent }, { max_measurement_bytes: 67108865 }).is_err()
}

## Transport-valid garbage remains a classified replacement, never an ignored
## check or a partially accepted claim envelope.
expect {
	fixture = empty_fixture({})?
	garbage = PictureBoot.present({ measured: List.repeat(7, 32), envelope: [83, 80, 67, 49] })?
	match PictureVerdict.parts(PictureVerdict.decide({ ..fixture, picture: garbage }, {})?) {
		Replace(MalformedPicture) => True
		_ => False
	}
}

## The expected fingerprint is a Python hashlib golden, independently framed
## from the domain, NUL and four zero length bytes; it is not made by decide.
empty_fixture : {} -> Try(PictureVerdict.Props, _)
empty_fixture = |_unused| {
	root_name = { namespace: "http://www.w3.org/1999/xhtml", prefix: "", local: "main" }
	envelope = PictureCodec.make({ root_name, batch_bytes: 0, fingerprint: [222, 82, 12, 126, 23, 78, 230, 243, 90, 25, 151, 86, 13, 236, 249, 131, 251, 92, 156, 141, 50, 92, 239, 183, 89, 172, 85, 100, 184, 206, 129, 169], expected: List.repeat(7, 32), physical_count: 0, containers: [{ owner: Mount, role: Children, children: [] }], logical: [], runs: [], bindings: [], scaffolds: [] }, {})?
	picture = PictureBoot.present({ measured: List.repeat(7, 32), envelope: PictureCodec.encode(envelope) })?
	Ok({ picture, root_name, batch: [], capture: Ok([]), next: 1, free: [] })
}
