// Tailwind for the site and its live examples. Paths are relative to this
// file; `blueprint run site` builds www/static/signals.css from www/input.css.
module.exports = {
  content: {
    relative: true,
    files: [
      "../examples/**/*.roc",
      "./templates/**/*.html",
      "./content/**/*.md",
      "./static/**/*.mjs",
    ],
  },
  theme: {
    extend: {},
  },
  plugins: [],
};
