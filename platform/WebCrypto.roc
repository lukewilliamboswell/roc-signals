import Core
import Engine

## Cryptography through the ordinary effect channel. The browser keeps keys
## non-extractable; Roc owns parameters, envelopes and the decision to unlock.
## Use these asks in effect sites. Every operation is scoped: disposing its
## site or superseding its input discards the answer. Browser work already
## running may continue, within the platform's operation bound.
WebCrypto := [].{

	## A non-extractable AES-256-GCM key. Keep it in a cell or local state
	## while unlocked; releasing its last Roc reference releases the browser
	## key. Other values holding it, such as a resource's answer, keep it alive.
	## Keys cannot be serialized, exported, sent to a port or sent to a worker.
	Key : Core.CryptoKey

	## Closed SHA-2 choices for hashing bytes.
	Hash : [Sha256, Sha384, Sha512]

	## Why a cryptographic request failed. InvalidParameters covers a salt
	## shorter than 16 bytes, zero iterations, an IV other than 12 bytes or
	## ciphertext shorter than its 16-byte authentication tag.
	## TooLarge covers the deployment's byte or iteration ceiling. Refused
	## covers the in-flight bound, key slots and pending or running operations,
	## including canceled operations whose browser promises have not settled.
	## Unavailable means secure browser cryptography is absent. NotAuthentic
	## means GCM authentication failed; no plaintext is delivered. Failed is
	## another failure reported by the cryptography service.
	Error : Core.CryptoError

	## The PBKDF2-HMAC parameters that derive an AES-256-GCM key. Generate a
	## fresh salt with random_bytes when creating an envelope, save it beside
	## the ciphertext, and use the same parameters when unlocking. Passwords
	## are exact UTF-8, without normalization. Iterations are required: choose
	## a cost for the application; mount limits cap it rather than choosing it.
	DeriveProps := {
		password : Str,
		salt : List(U8),
		iterations : U32,
		hash : [Sha256, Sha512] ?? Sha256,
	}

	## Bytes to seal and additional authenticated data, such as a project id.
	## Associated data is authenticated but is not included in the ciphertext.
	EncryptProps := { plaintext : List(U8), associated : List(U8) ?? [] }

	## One AES-256-GCM envelope fragment: a 12-byte IV and ciphertext with its
	## appended 128-bit tag. Keep the salt and KDF parameters in your envelope.
	Sealed : { iv : List(U8), ciphertext : List(U8) }

	## A saved sealed fragment and the exact associated data used at encryption.
	DecryptProps := { iv : List(U8), ciphertext : List(U8), associated : List(U8) ?? [] }

	## Ask for cryptographically secure bytes, independently of the boot seed.
	## Zero is valid and reads no entropy. A request beyond maxCryptoBytes
	## answers TooLarge; unavailable secure entropy answers Unavailable.
	random_bytes : U64 -> Engine.Ask(List(U8), Error)
	random_bytes = |count| Core.make_ask(Crypto(RandomBytes(count)), read_bytes)

	## Derive one non-extractable AES-256-GCM key with PBKDF2-HMAC. A key is an
	## ordinary value: put it in a cell while unlocked and remove it to lock.
	## Salt must have at least 16 bytes and iterations must be positive, else
	## InvalidParameters. Combined password/salt bytes beyond maxCryptoBytes,
	## or iterations beyond maxCryptoIterations, answer TooLarge. An instance
	## already holding 64 keys answers Refused for another derivation.
	derive_key : DeriveProps -> Engine.Ask(Key, Error)
	derive_key = |props| Core.make_ask(Crypto(DeriveKey({ password: props.password, salt: props.salt, iterations: props.iterations, hash: props.hash })), read_key)

	## Seal bytes with a fresh secure 96-bit IV chosen by the platform for
	## every operation. There is no caller-supplied encryption IV to reuse.
	## Plaintext and associated data together, plus the 16-byte authentication
	## tag, must fit maxCryptoBytes, else TooLarge. The returned ciphertext
	## includes that tag; keep its IV alongside it in the saved envelope.
	encrypt : Key, EncryptProps -> Engine.Ask(Sealed, Error)
	encrypt = |key, props| Core.make_ask(Crypto(Encrypt({ key, plaintext: props.plaintext, associated: props.associated })), read_sealed)

	## Authenticate before returning any plaintext. Wrong passwords, changed
	## ciphertext and changed associated data answer NotAuthentic alike.
	## A non-12-byte IV or ciphertext shorter than 16 bytes answers
	## InvalidParameters. Ciphertext and associated data together must fit
	## maxCryptoBytes, else TooLarge. An empty plaintext is valid.
	decrypt : Key, DecryptProps -> Engine.Ask(List(U8), Error)
	decrypt = |key, props| Core.make_ask(Crypto(Decrypt({ key, iv: props.iv, ciphertext: props.ciphertext, associated: props.associated })), read_bytes)

	## Hash bytes with the chosen SHA-2 algorithm. For a file already behind a
	## handle use File.sha256 to avoid reading its bytes into Roc. Input beyond
	## maxCryptoBytes answers TooLarge; the fixed digest output is excluded
	## from that ceiling, so hashing empty bytes is legal at a zero ceiling.
	digest : Hash, List(U8) -> Engine.Ask(List(U8), Error)
	digest = |hash, bytes| Core.make_ask(Crypto(Hash({ hash, bytes })), read_bytes)
}

read_bytes : Core.Result -> Try(List(U8), WebCrypto.Error)
read_bytes = |result| match result {
	CryptoBytes(bytes) => Ok(bytes)
	CryptoFailed(reason) => Err(reason)
	Refused => Err(Refused)
	_ => crash "contract: a byte crypto request received a result of another kind"
}

read_key : Core.Result -> Try(WebCrypto.Key, WebCrypto.Error)
read_key = |result| match result {
	CryptoKey(key) => Ok(key)
	CryptoFailed(reason) => Err(reason)
	Refused => Err(Refused)
	_ => crash "contract: derive_key received a result of another kind"
}

read_sealed : Core.Result -> Try(WebCrypto.Sealed, WebCrypto.Error)
read_sealed = |result| match result {
	CryptoSealed(sealed) => Ok(sealed)
	CryptoFailed(reason) => Err(reason)
	Refused => Err(Refused)
	_ => crash "contract: encrypt received a result of another kind"
}

## A hash ask preserves the selected algorithm and the exact input bytes.
expect WebCrypto.digest(Sha384, [0, 255]).sent() == Crypto(Hash({ hash: Sha384, bytes: [0, 255] }))

## Randomness is an explicit request, including the legal empty request.
expect WebCrypto.random_bytes(0).sent() == Crypto(RandomBytes(0))

## Authentication and admission failures remain distinguishable typed values.
expect [read_bytes(CryptoFailed(NotAuthentic)), read_bytes(Refused)] == [Err(NotAuthentic), Err(Refused)]
