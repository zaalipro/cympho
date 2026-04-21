// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration

const plugin = require("tailwindcss/plugin")

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/cympho_web.ex",
    "../lib/cympho_web/**/*.*ex"
  ],
  theme: {
    extend: {
      colors: {
        canvas: "#08090a",
        panel: "#0f1011",
        surface: "#191a1b",
        "surface-hover": "#28282c",
        "text-primary": "#f7f8f8",
        "text-secondary": "#d0d6e0",
        "text-tertiary": "#8a8f98",
        "text-quaternary": "#62666d",
        brand: "#5e6ad2",
        accent: "#7170ff",
        "accent-hover": "#828fff",
        border: "rgba(255,255,255,0.08)",
        "border-subtle": "rgba(255,255,255,0.05)",
        success: "#27a644",
        emerald: "#10b981",
        line: "#141516",
        "line-tertiary": "#18191a",
      },
      fontFamily: {
        inter: [
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
        card: "8px",
        panel: "12px",
        large: "22px",
      },
      boxShadow: {
        subtle: "rgba(0,0,0,0.03) 0px 1.2px 0px",
        ring: "rgba(0,0,0,0.2) 0px 0px 0px 1px",
        elevated: "rgba(0,0,0,0.4) 0px 2px 4px",
        dialog:
          "rgba(0,0,0,0) 0px 8px 2px, rgba(0,0,0,0.01) 0px 5px 2px, rgba(0,0,0,0.04) 0px 3px 2px, rgba(0,0,0,0.07) 0px 1px 1px, rgba(0,0,0,0.08) 0px 0px 1px",
        focus: "rgba(0,0,0,0.1) 0px 4px 12px",
        inset: "rgba(0,0,0,0.2) 0px 0px 12px 0px inset",
      },
      letterSpacing: {
        display: "-1.056px",
        "display-lg": "-1.408px",
        "display-xl": "-1.584px",
        tight: "-0.704px",
        caption: "-0.13px",
        small: "-0.165px",
      },
      lineHeight: {
        display: "1.00",
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
