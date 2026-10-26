# Cympho design: Paper & Ink

One theme, three modes. Light is paper for reading and ink for deciding. Dark is the same figure turned over: the page is ink, and the decision sits on the one paper card. Whatever the mode, the thing the owner decides is on the single surface of opposite value.

## Modes

- **Light** ("Paper and ink"), **Dark** ("Ink and paper") and **System** (follows the device; the default for new users). Settings › Appearance offers exactly these three.
- `Cympho.Themes` is the registry. The mode is stored in `users.theme`, mirrored into the `theme` cookie, and stamped as `<html data-mode="light|dark|system">` by the root layout. Appearance pushes `set-theme`; `app.js` flips `data-mode` and the cookie without a reload.
- Users who had one of the twelve retired palettes keep a sensible mode: `Themes.normalize/1` maps dark palettes to Dark, light ones to Light and anything else to System, at read time (the old id is never written back).
- `designs/DESIGN-*.md` describe the retired palettes. They are history, not a spec.

## Tokens

| File | Holds |
|---|---|
| `assets/css/app.css` `:root` | The light mode: the r3 token set (`--page`, `--frame`, `--tray`, `--card`, `--ink`, `--ink-2`, `--accent`, the status hues, `--inv-*` …), radii, fonts, motion, phone geometry, then the legacy names (`--color-*`) mapped onto r3 tokens |
| `assets/css/themes.css` | The dark mode, written twice and kept identical: under `prefers-color-scheme: dark` unless `data-mode="light"`, and under `data-mode="dark"` |
| `assets/css/r3.css` | The shell and the shared components; every selector under `.cy-r3` (the body) |
| `assets/css/r3-pages/*.css` | Page rules, one file per page group, scoped by `[data-page="…"]` on the page frame (or `.set-main[data-section="…"]` for a Settings section): `home`, `task`, `work` (Tasks, Board), `agents` (Team, Agent), `money` (Spending, Settings), `onboarding`, `auth` (signed-out), `settings`, `planning` (new task, projects, goals, labels, launch checklist, repeating tasks), `governance` (approvals, board vote, reviews, activity, org chart, search, compare companies), `hire` (hire, remote agents, skills, plugins), `company` (spending limits, companies, export, import, docs), `ops` (Health, step log, work files) |

Rules:
- No colour literal outside the two token blocks. Components and pages use `var(--token)`; templates use Tailwind classes that resolve to tokens.
- Every colour token has a dark value. A legacy name that equals one r3 token is written as `var(<token>)` and follows the mode by itself; only names with their own value repeat in the dark block.
- Tailwind's colour families resolve to tokens with alpha channels (`--color-*-rgb`): blue/sky/cyan/teal → info (Working teal), emerald/green → success, amber/yellow/orange → warning, red/rose → error, violet/purple/fuchsia → `--cat-2`, slate/gray → `--idle`. Text on a primary fill uses `text-on-primary`.
- Surfaces climb `--page` < `--tray` < `--frame` = `--card`; in Dark, lighter means higher.
- Status is a word plus a shape, never colour alone: Working (teal, spinning ring), Waiting (amber, filled dot), Stopped (coral, crossed ring), Done (green, ticked ring), Idle (grey ring). Every status hue passes WCAG AA on every surface in both modes.
- Orange (`--accent`) marks selection only: the current destination, the current segment, a chosen option.
- Inside the resolution card (`.ink`) focus, accent and status re-scope to their inverse values automatically. Anything else placed there (fields, second lines, tiles, disabled rows) reads the `--inv-*` tokens.
- Focus: one style everywhere, a 2 px ring outside a 2 px gap (`--focus-ring`, `--focus-gap`), on `:focus-visible`.

## Type, shape, motion

- Inter (`--sans`) for text, JetBrains Mono (`--mono`) for IDs, times, amounts and counts (tabular figures). Loaded from Google Fonts in the root layout.
- Body 14/20; root H1 24/30 weight 500; a deep page's H1 28/34; the Next step title 24/30; caps eyebrows 12/16 weight 500. The floor is 12 px.
- Radii: frame 28, tray 20, card 16, row 12, field 8, pills fully round.
- Only live things move: the Working glyph spins and the Now capsule breathes while a run is live. Everything else is still. `prefers-reduced-motion` stops both and drops transitions.
- Targets: at least 24 px on desktop, 44 px on phones.

## Shell

The root layout (`controllers/layouts/root.html.heex`) draws one shell for every signed-in page. Pages never draw their own.

- **Rail** (248 px; 216 px at 1180 px and below): the company switch (power line from the company state; the runtime controls in its menu), search (⌘K opens the palette), New task (a secondary pill), the Main nav, the live team list, the account menu.
- **Main nav** (`CymphoWeb.Components.NavRail`): six destinations in a fixed order — Home, Inbox, Tasks, Team, Spending, Settings — each with its pages listed under it while it is current. Exactly one destination carries `aria-current`. Inbox carries the one count badge.
- **Team list** (`CymphoWeb.TeamRailLive`, rendered from the root layout so it survives live navigation): one row per agent with status and "N for you" chips, stopped agents pinned. It starts closed below 800 px of viewport height unless the owner opened it, and is closed on the Team page. The spending slot appears under it only at 80% of the limit or more, or when the company is paused.
- **Phone** (640 px and below): a top bar (company, Search, New, Settings) and the Main nav as a floating five-tab bar (Settings lives in the top bar). Deep pages hide the top bar and carry the same three tools in their own header.
- **Skip link** first in `<body>`, to `#main-content`.
- Onboarding renders with `shell: :bare` (no rail, no tab bar) and draws its own setup bar and step list.

## Page frame

`page_frame/1` (`CymphoWeb.Components.R3`) wraps every page, with `data-ui-complex-page`: a sticky context header and the tray. Settings sections use `settings_layout/1`, which renders the frame titled "Settings" with the section list; the section's first card carries the section's name. (The dev-only Prompt inspector is the one page outside it.)
- **Root pages** (the six destinations, the pages listed under them in the rail, Search, Documentation): the H1 is the rail label; controls at the header's end (a segmented filter or view switch, at most one secondary pill on phones, usually "New …").
- **Deep pages** (every detail, create and edit page): a breadcrumb to the list one level up ("‹ Goals › Edit goal"), and "Back to …" when the page was opened from somewhere other than its parent. The origin comes from `?from=`, accepted only through the allow-list in `UserAuth.safe_from/1`. The deep head is `section.head`: the H1, one `.sub` line, then `.chips` with the status and the page's secondary actions. On phones the crumb keeps only the Back pill (the H1 under it names the page; Task and Agent keep their own crumbs).
- **Page kinds.** A list page: an optional toolbar (`search_capsule`, `filter_menu`, a segmented status), then a `band_card` of `list_row`s or a `quiet_empty`, problems first; at most one `.strip` of 3–4 cells (`.strip.s3` / `.s4`), never a row of stat tiles. A detail page: content bands, then an aside `band_card` "Details" with `kv_list class="wide"` (ids, dates, owners live only there), and a destructive action last as `.pl.warn`. A form page: `form_pair/1`. A log: `list_row`s with a kind tile and the payload in a closed disclosure; a real table is `.tbl-w > table.tbl`, whose `m-hide` columns drop on phones.
- The page's flash is `flash_line/1`, right under the header (inside a deep head).

## The Next step

A page that asks the owner to decide opens with one Next step: a pair of cards. Home, Inbox, Tasks, Task, Team, Agent, Spending and Settings always do; the decision pages (an approval, a board vote, a spending limit that was hit, a repeating task that failed or has no schedule, a paused company, export, import, Health's next fix) do while there is something to decide. Other list pages have none: their "New …" pill is secondary.
- **Problem card** (paper): an eyebrow, a verb-first title, the object in the agent's own words, at most one instrument (run bars, a tick meter), and a footer link to the object.
- **Resolution card** (ink): what pressing does — consequence rows or the decision form itself — the effect sentence, then the footer with the ⌘↵ hint, one secondary and **the page's only primary** (`primary_pill/1`). Everything else on a page is a secondary pill or a text link.
- **Order**: the company stopped at its spending limit, then problems, questions, reviews, approvals. Home and Inbox take the first item of `OwnerAttention.owner_order/1`; Tasks opens the first decision of its first group (Blocked, then Waiting on you); Task and Agent lead with their own object's decision in the same order (OwnerAttention keeps one row per task, the problem before the question); Team, Spending and Settings lead with their own subject (a stopped agent, the limit, alerts) after a company stop.
- **List pages** (Inbox, Tasks) open the first item in place as the pair; every other item is a closed row with one secondary verb.
- **All clear**: the eyebrow "All clear", the page's own title and, when there is an action, its one primary. With no action the problem card stands alone.
- **Forms** are pairs too (`form_pair/1`): the field cards on paper, and the ink card saying what saving does, with Cancel as its secondary and the submit as the page's only primary.
- When agents are switched off on the server and nothing needs the owner, the pair says so ("Turn agents on").
- A question keeps its task Blocked and offers 2–4 numbered answers plus "write your own".
- Copy comes from one place: `CymphoWeb.NextStep` holds the effect sentences for every owner item, so one decision reads the same on every page.

## Components

- `CymphoWeb.Components.R3`: `page_frame`, `next_step`, `problem_card`, `ink_card`, `consequences`, `ink_note`, `ink_foot`, `primary_pill`, `pill`, `ghost_pill`, `text_link`, `chip`, `quote_mark`, `option_rows`, `status_glyph`, `status_word`, `run_bars`, `tick_meter`, `now_capsule`, `object_tile`, `kv_list`, `segmented`, `band_card`, `needs_row`, `team_row`, `search_capsule`, `composer`, `quiet_empty`, `form_pair`, `list_row` (a row whose title link covers it; only its `actions` and `below` slots take controls), `filter_menu`, `flash_line`, and the icon sprite (`r3_sprite`, `r3_icon`).
- In the same look, from `CymphoWeb.Components` / `CoreComponents`: `input/1` (`.fld`: label, one help line, the error with `aria-invalid` + `aria-describedby`; 16 px and 44 px tall on phones), `select_menu/1` and the date pickers (`.fld-sel` trigger, `.sel-pop` popover), `modal/1` (a paper dialog, a bottom sheet on phones), `overflow_menu/1` + `menu_item/1`, `density_switch/1`.
- Status is `status_word` (glyph + word) for live, health and outcome states and `.tag` for neutral attributes; lifecycle defaults ("Active", "Enabled") are not printed. An agent's word comes from `AgentLive.Parts.status/2` everywhere it is shown.
- `CymphoWeb.NextStep`: `pair/1` for an owner item, `row/1` for a closed Needs-you row, `paused_step/1`, `server_off_step/1`, `all_clear/1`, and `answer_from_params/1` for answer forms.
- A page-only variant is built from these components in the page's own module; it does not copy their markup.
- Simple is the default view. Advanced-only blocks carry `ui-advanced-only` and sit below the Simple blocks; Advanced-only pages keep their rail entries Advanced-only, and no Simple-visible link points at them.
- Every `<details>` a LiveView renders has a stable id and `phx-mounted={JS.ignore_attributes("open")}` (a server-decided `open` uses `data-open` with the `ServerOpen` hook).

## Checks

- `test/cympho_web/r3_css_contract_test.exs`: the two dark copies are identical, every colour token has a dark value, every `var()` names a declared token, and `r3.css` and `r3-pages/*.css` contain no colour literal. Templates write no colour either, except a user's own data colour (a label, a project) as a 10 px `.sw` swatch beside its text.
- `test/cympho_web/details_open_state_test.exs`: the `<details>` rule above.
- `CymphoWeb.R3PageHelpers.assert_r3_page/2` in page tests: the frame, one H1, the crumb on deep pages, and every `.pw` on an ink card.
- Contrast: every token pair the pages use passes WCAG AA in both modes: 4.5:1 for text, 3:1 for marks, field borders and focus rings.
- Every page: one H1, one current destination, one primary, no horizontal overflow at 1440, 1024 and 390 px.
