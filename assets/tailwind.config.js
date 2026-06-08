const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

// Status color families collapse to a single semantic CSS-var token (full alpha
// support via the channel form) so badges/dots stay readable on every theme's
// canvas — status doesn't need five shades of green. Each theme sets the
// matching --color-<token>-rgb channels (app.css :root + themes.css).
const STATUS_SHADES = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950]
const semantic = (token) =>
  Object.fromEntries(
    STATUS_SHADES.map((shade) => [shade, `rgb(var(--color-${token}-rgb) / <alpha-value>)`])
  )

// Cympho is dark-only per DESIGN.md. Tokens map to CSS variables defined in
// app.css. Spec names (surface-1, ink, hairline, primary…) are the
// canonical utilities; legacy names (panel, surface, text-primary, border,
// brand…) are kept as aliases pointing to the same vars so the existing
// templates compile without a sweeping rewrite.

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/cympho_web.ex",
    "../lib/cympho_web/**/*.*ex"
  ],
  // Hero icon classes built from helper-returned names (e.g. `hero-#{icon}-mini`)
  // never appear as literal strings in source, so Tailwind's JIT can't generate
  // them. List them here so they always ship.
  safelist: [
    "hero-eye-mini",
    "hero-play-mini",
    "hero-pause-mini",
    "hero-exclamation-triangle-mini",
    "hero-bell-alert-mini",
    "hero-information-circle-mini",
    "hero-check-circle-mini",
    "hero-minus-circle-mini",
    "hero-sparkles-mini",
    "hero-no-symbol-mini",
    "hero-user-group-mini",
    "hero-arrow-right-circle-mini",
    // Date/time picker glyphs — only ever referenced as literals inside the
    // DatePicker hook (assets/js/app.js), so the JIT can't see them.
    "hero-calendar-mini",
    "hero-clock-mini",
    "hero-chevron-left-mini",
    "hero-chevron-right-mini",
  ],
  theme: {
    extend: {
      colors: {
        // Canvas + surface ladder
        canvas: "var(--color-canvas)",
        "surface-1": "var(--color-surface-1)",
        "surface-2": "var(--color-surface-2)",
        "surface-3": "var(--color-surface-3)",
        "surface-4": "var(--color-surface-4)",

        // Legacy aliases
        panel: "var(--color-panel)",
        surface: "var(--color-surface)",
        "surface-hover": "var(--color-surface-hover)",
        subtle: "var(--color-subtle)",

        // Ink
        ink: "var(--color-ink)",
        "ink-muted": "var(--color-ink-muted)",
        "ink-subtle": "var(--color-ink-subtle)",
        "ink-tertiary": "var(--color-ink-tertiary)",

        // Legacy aliases
        "text-primary": "var(--color-text-primary)",
        "text-secondary": "var(--color-text-secondary)",
        "text-tertiary": "var(--color-text-tertiary)",
        "text-quaternary": "var(--color-text-quaternary)",

        // Brand
        primary: "rgb(var(--color-primary-rgb) / <alpha-value>)",
        "primary-hover": "var(--color-primary-hover)",
        "primary-focus": "var(--color-primary-focus)",
        brand: "rgb(var(--color-primary-rgb) / <alpha-value>)",
        accent: "rgb(var(--color-primary-rgb) / <alpha-value>)",
        "accent-hover": "var(--color-accent-hover)",
        // Text/icon color that sits ON a primary-filled surface (per theme).
        "on-primary": "var(--color-on-primary)",

        // Hairlines
        hairline: "var(--color-hairline)",
        "hairline-strong": "var(--color-hairline-strong)",
        "hairline-tertiary": "var(--color-hairline-tertiary)",
        border: "var(--color-border)",
        "border-subtle": "var(--color-border-subtle)",

        // Semantic
        success: "var(--color-success)",
        warning: "var(--color-warning)",
        error: "var(--color-error)",
        overlay: "var(--color-overlay)",

        button: "var(--color-button-bg)",
        "button-hover": "var(--color-button-hover)",

        // ── Claude semantic palette (Anthropic official, DESIGN.md) ─────
        // Anchored on Claude's real tokens — success #5db872, warning
        // #d4a017, accent-amber #e8a55a, error #c64545, accent-teal #5db8a6.
        // Claude uses warm TEAL for info/active status, never cool blue, so
        // blue/sky/cyan are remapped onto the teal anchor. Roles (violet/
        // purple/fuchsia) have no Claude equivalent; kept muted + warm.
        // extend deep-merges, so only the shades used in templates are set.
        // Status families → semantic CSS-var tokens (full alpha support) so
        // badges/dots read on every theme's canvas. Cool blue/sky/cyan/teal map
        // to the info token (Claude uses warm teal for info, never cool blue).
        blue: semantic("info"),
        sky: semantic("info"),
        cyan: semantic("info"),
        teal: semantic("info"),
        emerald: semantic("success"),
        green: semantic("success"),
        amber: semantic("warning"),
        yellow: semantic("warning"),
        orange: semantic("warning"),
        red: semantic("error"),
        rose: semantic("error"),
        violet: { 200: "#CFC0D6", 300: "#B6A1C2", 500: "#7F628E" },
        purple: { 400: "#9A7CA8", 500: "#7F628E" },
        fuchsia: { 300: "#CB9BAD", 500: "#A96B83" },
        slate: { 300: "#B4ADA2", 400: "#9A9388", 500: "#807A6F" },
        gray: { 300: "#C2BBB0", 400: "#9A9388", 500: "#807A6F", 700: "#4A453E" },
        zinc: { 100: "#E8E3DA", 200: "#D6D0C6", 500: "#807A6F" },
      },
      fontFamily: {
        // Theme-driven — the real stacks live in CSS vars (app.css :root +
        // themes.css) so each theme selects its own display/body/mono faces.
        sans: ["var(--font-body)"],
        serif: ["var(--font-display)"],
        mono: ["var(--font-mono)"],
      },
      fontWeight: {
        510: "510",
        590: "590",
      },
      borderRadius: {
        // Theme-driven radius — values resolve to CSS vars so each theme can
        // reshape corners (Blocks→pill, Circuit→sharp) with zero template edits.
        xs: "var(--radius-xs)",
        sm: "var(--radius-sm)",
        md: "var(--radius-md)",
        lg: "var(--radius-lg)",
        xl: "var(--radius-xl)",
        "2xl": "var(--radius-2xl)",
        "3xl": "var(--radius-3xl)",
        xxl: "var(--radius-xxl)",
        pill: "var(--radius-pill)",
        // Legacy aliases — `card` was used like spec lg, `panel` like xl.
        card: "var(--radius-card)",
        panel: "var(--radius-panel)",
        large: "var(--radius-xxl)",
        // Semantic radii for shared components (button/input/field).
        button: "var(--radius-button)",
        input: "var(--radius-input)",
        field: "var(--radius-field)",
      },
      boxShadow: {
        // Elevation: hairline ring + layered ambient shadows + an inset
        // top-highlight (the craft tell). The ambient black and the inset
        // highlight are tokens (--shadow-rgb / --shadow-strength /
        // --shadow-inset-highlight) so light themes soften shadows and drop the
        // white highlight, and shadow-heavy themes (Nocturne) deepen them.
        ring: "0px 0px 0px 1px var(--color-border)",
        "ring-hover": "0px 0px 0px 1px var(--color-border-hover)",
        subtle:
          "0 0 0 1px var(--color-border), 0 1px 2px rgb(var(--shadow-rgb) / calc(0.20 * var(--shadow-strength)))",
        card:
          "inset 0 1px 0 0 var(--shadow-inset-highlight), 0 0 0 1px var(--color-border), 0 1px 2px rgb(var(--shadow-rgb) / calc(0.18 * var(--shadow-strength))), 0 4px 12px rgb(var(--shadow-rgb) / calc(0.20 * var(--shadow-strength)))",
        raised:
          "inset 0 1px 0 0 var(--shadow-inset-highlight), 0 0 0 1px var(--color-border-hover), 0 2px 4px rgb(var(--shadow-rgb) / calc(0.22 * var(--shadow-strength))), 0 8px 20px rgb(var(--shadow-rgb) / calc(0.26 * var(--shadow-strength)))",
        elevated:
          "inset 0 1px 0 0 var(--shadow-inset-highlight), 0 0 0 1px var(--color-border), 0 4px 12px rgb(var(--shadow-rgb) / calc(0.26 * var(--shadow-strength))), 0 12px 28px rgb(var(--shadow-rgb) / calc(0.30 * var(--shadow-strength)))",
        dialog:
          "inset 0 1px 0 0 var(--shadow-inset-highlight), 0 0 0 1px var(--color-border), 0 8px 24px rgb(var(--shadow-rgb) / calc(0.32 * var(--shadow-strength))), 0 24px 60px rgb(var(--shadow-rgb) / calc(0.40 * var(--shadow-strength)))",
        focus:
          "0 0 0 1px var(--color-canvas), 0 0 0 3px color-mix(in srgb, var(--color-primary) 55%, transparent), 0 0 12px 0 color-mix(in srgb, var(--color-primary) 35%, transparent)",
        inset: "inset 0px 0px 0px 1px rgb(var(--shadow-rgb) / calc(0.20 * var(--shadow-strength)))",
      },
      letterSpacing: {
        // Negative tracking per DESIGN.md
        "display-xl": "-3.0px",
        "display-lg": "-1.8px",
        "display-md": "-1.0px",
        headline: "-0.6px",
        "card-title": "-0.4px",
        subhead: "-0.2px",
        "body-lg": "-0.1px",
        body: "-0.05px",
        eyebrow: "0.4px",
        // Legacy aliases
        display: "0",
        tight: "0",
        caption: "0",
        small: "0",
      },
      lineHeight: {
        display: "1.10",
        relaxed: "1.60",
      },
    },
  },
  plugins: [
    plugin(({addVariant}) => addVariant("phx-no-loading", [".phx-no-loading&", ".phx-no-loading &"])),
    plugin(({addVariant}) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({addVariant}) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({addVariant}) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),

    // Typography scale per DESIGN.md — exposes named utilities so we stop
    // paying the arbitrary text-[Xpx] tax in templates.
    // Heroicons → CSS classes. Drop a `hero-pencil` class anywhere, get the
    // outline icon as a current-color masked SVG. Three weights:
    //   `hero-pencil`        → outline (24px stroke)
    //   `hero-pencil-solid`  → solid (24px fill)
    //   `hero-pencil-mini`   → mini (20px solid)
    // The component (`<.icon>`) just emits a `<span>` with this class.
    plugin(function({matchComponents, theme}) {
      let iconsDir = path.join(__dirname, "../deps/heroicons/optimized")
      let values = {}
      let icons = [
        ["", "/24/outline"],
        ["-solid", "/24/solid"],
        ["-mini", "/20/solid"]
      ]
      icons.forEach(([suffix, dir]) => {
        fs.readdirSync(path.join(iconsDir, dir)).forEach(file => {
          let name = path.basename(file, ".svg") + suffix
          values[name] = {name, fullPath: path.join(iconsDir, dir, file)}
        })
      })
      matchComponents({
        "hero": ({name, fullPath}) => {
          let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
          let size = theme("spacing.6")
          if (name.endsWith("-mini")) size = theme("spacing.5")
          return {
            [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
            "-webkit-mask": `var(--hero-${name})`,
            "mask": `var(--hero-${name})`,
            "mask-repeat": "no-repeat",
            "background-color": "currentColor",
            "vertical-align": "middle",
            "display": "inline-block",
            "width": size,
            "height": size
          }
        }
      }, {values})
    }),

    plugin(({addUtilities}) => addUtilities({
      ".text-display-xl": {
        fontFamily: "var(--font-display)",
        fontSize: "80px", lineHeight: "1.05", letterSpacing: "-1.5px", fontWeight: "600"
      },
      ".text-display-lg": {
        fontFamily: "var(--font-display)",
        fontSize: "56px", lineHeight: "1.10", letterSpacing: "-1.0px", fontWeight: "600"
      },
      ".text-display-md": {
        fontFamily: "var(--font-display)",
        fontSize: "40px", lineHeight: "1.15", letterSpacing: "-0.5px", fontWeight: "600"
      },
      ".text-headline": {
        fontFamily: "var(--font-display)",
        fontSize: "28px", lineHeight: "1.20", letterSpacing: "-0.3px", fontWeight: "600"
      },
      ".text-card-title": {
        fontFamily: "var(--font-display)",
        fontSize: "22px", lineHeight: "1.25", letterSpacing: "-0.2px", fontWeight: "500"
      },
      ".text-subhead": {
        fontSize: "20px", lineHeight: "1.40", letterSpacing: "-0.2px", fontWeight: "400"
      },
      ".text-body-lg": {
        fontSize: "18px", lineHeight: "1.50", letterSpacing: "-0.1px", fontWeight: "400"
      },
      ".text-body": {
        fontSize: "16px", lineHeight: "1.50", letterSpacing: "-0.05px", fontWeight: "400"
      },
      ".text-body-sm": {
        fontSize: "14px", lineHeight: "1.50", letterSpacing: "0", fontWeight: "400"
      },
      ".text-caption": {
        fontSize: "12px", lineHeight: "1.40", letterSpacing: "0", fontWeight: "400"
      },
      ".text-button": {
        fontSize: "14px", lineHeight: "1.20", letterSpacing: "0", fontWeight: "500"
      },
      ".text-eyebrow": {
        fontSize: "13px", lineHeight: "1.30", letterSpacing: "0.4px", fontWeight: "500"
      },
      ".text-mono": {
        fontFamily: "var(--font-mono)",
        fontSize: "13px", lineHeight: "1.50", letterSpacing: "0", fontWeight: "400"
      },
    })),
  ]
}
