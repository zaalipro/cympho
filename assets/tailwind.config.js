const plugin = require("tailwindcss/plugin")

module.exports = {
  darkMode: 'class',
  content: [
    "./js/**/*.js",
    "../lib/cympho_web.ex",
    "../lib/cympho_web/**/*.*ex"
  ],
  theme: {
    extend: {
      colors: {
        canvas: "var(--color-canvas)",
        panel: "var(--color-panel)",
        surface: "var(--color-surface)",
        "surface-hover": "var(--color-surface-hover)",
        subtle: "var(--color-subtle)",
        "text-primary": "var(--color-text-primary)",
        "text-secondary": "var(--color-text-secondary)",
        "text-tertiary": "var(--color-text-tertiary)",
        "text-quaternary": "var(--color-text-quaternary)",
        brand: "var(--color-brand)",
        accent: "var(--color-accent)",
        "accent-hover": "var(--color-accent-hover)",
        border: "var(--color-border)",
        "border-subtle": "var(--color-border-subtle)",
        success: "var(--color-success)",
        error: "var(--color-error)",
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
        card: "12px",
        panel: "16px",
        large: "24px",
        xl: "32px",
      },
      boxShadow: {
        ring: "0px 0px 0px 1px var(--color-border)",
        "ring-hover": "0px 0px 0px 1px var(--color-border-hover)",
        elevated: "0px 0px 0px 1px var(--color-border), 0px 4px 24px rgba(0,0,0,0.05)",
        focus: "0px 0px 0px 2px var(--color-brand)",
        dialog: "0px 0px 0px 1px var(--color-border), 0px 8px 32px rgba(0,0,0,0.08)",
        subtle: "0px 2px 8px rgba(0,0,0,0.04)",
        inset: "inset 0px 0px 0px 1px rgba(0,0,0,0.06)",
      },
      letterSpacing: {
        display: "0",
        "display-lg": "0",
        "display-xl": "0",
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
    plugin(({addVariant}) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"]))
  ]
}
