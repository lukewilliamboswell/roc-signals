import pf.Engine exposing [Cell]
import CommentForm
import Comments
import Route
import Story

## The article page's state, as cells of the app's store: the article, its
## comments and the comment box, each a cell of its own, so a keystroke in
## the box wakes the box's readers and no one else's. The app nests these
## cells in its store (`AppStore`); this module never names the store, and
## each cell's place in it comes from the description. The description
## also hands out the write that starts the page again, which a move to
## another kind of page applies.
##
## What a change to one of them means for another (an accepted comment
## asks for the list again; a deleted article sends the reader home) is
## decided in the page's view (`ArticlePage`), which composes the cells'
## reactions.
Article := [].{

	## The handles on the page's cells, in a store whose storage is `st`.
	Cells(st) : { story : Cell(st, Story), comments : Cell(st, Comments), form : Cell(st, CommentForm) }

	## What the app's store holds for this page: the handles on its cells,
	## and the write that starts every one of them again.
	Handles(st) : { cells : Cells(st), reset : Engine.Write(st) }

	## The page's cells, for a reader at no article yet. `reset` is
	## generated from this description: a cell added here is started again
	## with the rest, and whoever applies `reset` need not know.
	cells : {} -> Engine.Cells(whole, _, Handles(whole))
	cells = |{}| {
		story: Engine.cell(Story.init("")),
		comments: Engine.cell(Comments.init("")),
		form: Engine.cell(CommentForm.init),
	}.Engine.Cells.with_reset(|cells, reset| { cells, reset })

	## Whether a move from `from` to `url` stays on the same kind of page.
	same_kind : Str, Str -> Bool
	same_kind = |from, url| Route.kind(Route.of_url(from)) == Route.kind(Route.of_url(url))

	## The slug of the article at `url`, or `""`.
	slug_of : Str -> Str
	slug_of = |url| Route.article_slug(Route.of_url(url))
}
