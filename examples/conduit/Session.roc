## Session state: the JWT and username persist in namespaced localStorage
## keys (all public examples share one origin, so keys are app-prefixed).
## The storage signals resolve before first render, so a restored session
## is visible on the very first frame with no post-mount flash.
import pf.Browser
import pf.Signal

Session := [Anonymous, SignedIn({ token : Str, username : Str })].{
	is_eq : Session, Session -> Bool
	is_eq = |left, right|
		match left {
			Anonymous => match right {
				Anonymous => True
				SignedIn(_) => False
			}
			SignedIn(left_user) => match right {
				Anonymous => False
				SignedIn(right_user) => left_user == right_user
			}
		}

	jwt_key : Str
	jwt_key = "conduit.jwt"

	username_key : Str
	username_key = "conduit.username"

	current : () -> Signal.Signal(Session)
	current = || {
		stored = { jwt: Browser.local_storage_text(jwt_key), username: Browser.local_storage_text(username_key) }.Signal
		stored.map(
			|value|
				match value.jwt {
					StorageValue(token) =>
						match value.username {
							StorageValue(name) => SignedIn({ token: token, username: name })
							_ => Anonymous
						}
					_ => Anonymous
				},
		)
	}

	is_signed_in : Session -> Bool
	is_signed_in = |session|
		match session {
			SignedIn(_) => True
			Anonymous => False
		}

	token_of : Session -> Str
	token_of = |session|
		match session {
			SignedIn(user) => user.token
			Anonymous => ""
		}

	username_of : Session -> Str
	username_of = |session|
		match session {
			SignedIn(user) => user.username
			Anonymous => ""
		}

	persist_token : Str -> _
	persist_token = |token| Browser.set_local_storage_text(jwt_key, token)

	persist_username : Str -> _
	persist_username = |name| Browser.set_local_storage_text(username_key, name)

	clear_token = Browser.remove_local_storage(jwt_key)

	clear_username = Browser.remove_local_storage(username_key)
}
