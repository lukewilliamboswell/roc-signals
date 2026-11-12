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
    extend: {
      // IBM Plex, served from www/static/fonts/ and declared in input.css.
      fontFamily: {
        sans: ['"IBM Plex Sans"', "ui-sans-serif", "system-ui", "sans-serif"],
        mono: ['"IBM Plex Mono"', "ui-monospace", "SFMono-Regular", "Menlo", "Consolas", "monospace"],
      },
      // Roc's violet: 600 is the language's own violet and 700 the darker
      // facet of its logo. The theme spends it only on what is live or
      // actionable, so status colors stay free to mean status.
      colors: {
        accent: {
          50: "#f6f1fe",
          100: "#ece2fd",
          200: "#d9c6fb",
          300: "#c0a2f8",
          400: "#ab86f5",
          500: "#9b6bf2",
          600: "#7c38f5",
          700: "#612bde",
          800: "#4b1fb4",
          900: "#38188a",
          950: "#230f5a",
        },
      },
    },
  },
  plugins: [],
};
