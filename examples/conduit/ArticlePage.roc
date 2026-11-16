import pf.Engine exposing [Elem]
import pf.Html
import AppStore
import CommentForm
import Comments
import Fetch
import Story
import Styles

## The article page: an article, its comments and the comment box, drawn
## over the article page's cells in the app's store (`Article`). The page
## decides what a change to one means for another, by composing their
## reactions; it takes no props, since whatever it needs from the rest of
## the app is a cell it reads.
ArticlePage := [].{

	## What the answer to a posted comment writes, decided once from the
	## form as it is when the answer arrives: the form records how it
	## ended, and an accepted comment asks for the list again.
	comment_answered : CommentForm, Fetch.Submit, Try(Engine.Response, Engine.HttpFailure) -> List(Engine.Write(_))
	comment_answered = |form, sent, res| {
		art = AppStore.cells.article.cells
		answer = form.answered(sent, res)
		recorded = art.form.set(answer.form)
		if (answer.posted) [recorded, art.comments.update(|c| c.refetched())] else [recorded]
	}

	## What the answer to a deletion of the article writes, decided once
	## from the story as it is when the answer arrives: the story records
	## the answer, and a deleted article asks to go home.
	delete_answered : Story, Fetch.Submit, Try(Engine.Response, Engine.HttpFailure) -> List(Engine.Write(_))
	delete_answered = |story, sent, res| {
		answer = story.delete_answered(sent, res)
		recorded = AppStore.cells.article.cells.story.set(answer.story)
		if (answer.deleted) [recorded, AppStore.asking(AppStore.home_url)] else [recorded]
	}

	## The page. Each part is drawn by its own module over the cells this
	## page hands it: the page imports the store, the parts do not.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| {
		art = AppStore.cells.article.cells
		session = AppStore.cells.session.signal()
		target = art.story.signal().map2(session, |s, who| { slug: s.slug(), token: who.token() })
		Html.section(
			"Article",
			Styles.wide_page,
			[
				Story.load(art.story.state()),
				Comments.load(art.comments.state()),
				Story.delete_site(art.story.state(), Engine.react_by(art.story.signal(), ArticlePage.delete_answered)),
				Comments.delete_site(art.comments.state()),
				Story.favorite_site(art.story.state()),
				Story.view(
					{ story: art.story, session: AppStore.cells.session, nav: AppStore.cells.nav },
					Comments.view(
						{ comments: art.comments, session: AppStore.cells.session },
						CommentForm.view(art.form.state(), target, Engine.react_by(art.form.signal(), ArticlePage.comment_answered)),
					),
				),
			],
		)
	}
}
