const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

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
        primary: "var(--color-primary)",
        "primary-hover": "var(--color-primary-hover)",
        "primary-focus": "var(--color-primary-focus)",
        brand: "var(--color-brand)",
        accent: "var(--color-accent)",
        "accent-hover": "var(--color-accent-hover)",

        // Hairlines
        hairline: "var(--color-hairline)",
        "hairline-strong": "var(--color-hairline-strong)",
        "hairline-tertiary": "var(--color-hairline-tertiary)",
        border: "var(--color-border)",
        "border-subtle": "var(--color-border-subtle)",

        // Semantic
        success: "var(--color-success)",
        error: "var(--color-error)",
        overlay: "var(--color-overlay)",

        button: "var(--color-button-bg)",
        "button-hover": "var(--color-button-hover)",
      },
      fontFamily: {
        sans: [
          "Inter",
          "Inter Variable",
          "SF Pro Display",
          "-apple-system",
          "system-ui",
          "Segoe UI",
          "Roboto",
          "Oxygen",
          "Ubuntu",
          "Cantarell",
          "Open Sans",
          "Helvetica Neue",
          "sans-serif",
        ],
        serif: [
          "Inter",
          "Inter Variable",
          "SF Pro Display",
          "-apple-system",
          "system-ui",
          "Segoe UI",
          "Roboto",
          "sans-serif",
        ],
        mono: [
          "Berkeley Mono",
          "ui-monospace",
          "SF Mono",
          "Menlo",
          "monospace",
        ],
      },
      fontWeight: {
        510: "510",
        590: "590",
      },
      borderRadius: {
        // Spec scale (DESIGN.md)
        xs: "4px",
        sm: "6px",
        md: "8px",
        lg: "12px",
        xl: "16px",
        xxl: "24px",
        pill: "9999px",
        // Legacy aliases — `card` was used like spec lg, `panel` like xl.
        card: "12px",
        panel: "16px",
        large: "24px",
      },
      boxShadow: {
        // Refined-dark elevation: each = hairline ring + layered ambient
        // shadows with real alpha (visible on the lifted #0a0b0e canvas) +
        // an inset top-highlight (the craft tell). `card` = resting cards/
        // panels, `raised` = hover-lift/popovers.
        ring: "0px 0px 0px 1px var(--color-border)",
        "ring-hover": "0px 0px 0px 1px var(--color-border-hover)",
        subtle: "0 0 0 1px var(--color-border), 0 1px 2px rgba(0,0,0,0.40)",
        card: "inset 0 1px 0 0 rgba(255,255,255,0.04), 0 0 0 1px var(--color-border), 0 1px 2px rgba(0,0,0,0.35), 0 4px 12px rgba(0,0,0,0.35)",
        raised:
          "inset 0 1px 0 0 rgba(255,255,255,0.05), 0 0 0 1px var(--color-border-hover), 0 2px 4px rgba(0,0,0,0.40), 0 8px 20px rgba(0,0,0,0.45)",
        elevated:
          "inset 0 1px 0 0 rgba(255,255,255,0.05), 0 0 0 1px var(--color-border), 0 4px 12px rgba(0,0,0,0.45), 0 12px 28px rgba(0,0,0,0.50)",
        dialog:
          "inset 0 1px 0 0 rgba(255,255,255,0.06), 0 0 0 1px var(--color-border), 0 8px 24px rgba(0,0,0,0.55), 0 24px 60px rgba(0,0,0,0.60)",
        focus:
          "0 0 0 1px var(--color-canvas), 0 0 0 3px color-mix(in srgb, var(--color-primary) 55%, transparent), 0 0 12px 0 color-mix(in srgb, var(--color-primary) 35%, transparent)",
        inset: "inset 0px 0px 0px 1px rgba(0,0,0,0.20)",
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
        fontSize: "80px", lineHeight: "1.05", letterSpacing: "-3.0px", fontWeight: "600"
      },
      ".text-display-lg": {
        fontSize: "56px", lineHeight: "1.10", letterSpacing: "-1.8px", fontWeight: "600"
      },
      ".text-display-md": {
        fontSize: "40px", lineHeight: "1.15", letterSpacing: "-1.0px", fontWeight: "600"
      },
      ".text-headline": {
        fontSize: "28px", lineHeight: "1.20", letterSpacing: "-0.6px", fontWeight: "600"
      },
      ".text-card-title": {
        fontSize: "22px", lineHeight: "1.25", letterSpacing: "-0.4px", fontWeight: "500"
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
        fontFamily: "Berkeley Mono, ui-monospace, SF Mono, Menlo, monospace",
        fontSize: "13px", lineHeight: "1.50", letterSpacing: "0", fontWeight: "400"
      },
    })),
  ]
}
