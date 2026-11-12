## Who is using the app: nobody yet, or a signed-in user and the token the
## API gave them.
Session := [Anonymous, SignedIn({ token : Str, username : Str })].{

	is_eq : _

	## The API token, or `""` for an anonymous visitor.
	token : Session -> Str
	token = |s| match s {
		SignedIn(u) => u.token
		Anonymous => ""
	}

	## The user's name, or `""` for an anonymous visitor.
	username : Session -> Str
	username = |s| match s {
		SignedIn(u) => u.username
		Anonymous => ""
	}

	is_signed_in : Session -> Bool
	is_signed_in = |s| match s {
		SignedIn(_) => True
		Anonymous => False
	}
}

expect Session.SignedIn({ token: "t", username: "kim" }).username() == "kim"
expect Session.Anonymous.token() == ""
