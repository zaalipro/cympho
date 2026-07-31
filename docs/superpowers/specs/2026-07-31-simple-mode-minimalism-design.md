# Simple mode: minimalism pass

Date: 2026-07-31

## Problem

Simple mode hides *panels* but still speaks the operator's language. A first-time
owner lands on Home and reads "Autonomous operating readiness needs review",
"Wake loop: Found 3 runtime items worth checking before broad autonomous runs",
"NEEDS SETUP" — then follows the card into `/operations`, which is a full ops
console ("Review service gates", "Delegated Work Queue", "Recent Runtime
Failures"). The mode filters density but not vocabulary, and the flow dead-ends
in screens that were never simplified.

## Goal

Simple mode reads as a calm, icon-led, plain-English product. Advanced mode is
untouched.

## Mechanism

`data-ui-mode` lives on `<html>` and is set client-side from `localStorage`
(`cympho-ui-mode`). The server cannot know the mode, so **both copies render and
CSS picks one** — the existing convention:

```css
html:not([data-ui-mode="simple"]) .ui-simple-only            { display: none !important }
html[data-ui-mode="simple"] [data-ui-complex-page] .ui-advanced-only { display: none !important }
```

Every change is one of exactly two shapes:

1. **Dual copy** — wrap the existing string in `.ui-advanced-only`, add a sibling
   `.ui-simple-only` plain-language node.
2. **Simple hides it** — add `.ui-advanced-only` to a node simple mode shouldn't show.

No existing advanced string is edited or deleted. Consequences:

- Advanced renders today's DOM byte-for-byte.
- Tests that assert copy verbatim keep passing.
- Simple copy must not collide with advanced copy, because `assert html =~ …`
  sees both variants in the rendered markup. Choose distinct wording.

All in-scope copy lives in `lib/cympho_web/` (the dashboard's attention items are
built in `dashboard_live/index.ex`, not the domain), so `lib/cympho/` is untouched.

## Icon vocabulary

One reused set so simple mode reads as a single system:

| Meaning | Icon |
|---|---|
| ready / ok | `hero-check-circle` |
| needs you | `hero-exclamation-triangle` |
| nothing running | `hero-pause-circle` |
| working | `hero-play-circle` |
| waiting | `hero-clock` |
| money | `hero-banknotes` |
| repo | `hero-link` |

## Screen by screen (simple mode only)

**Home** — attention items gain a `simple:` variant (icon + <=5-word title +
<=10-word detail + verb-first action). The triple `NEEDS SETUP` badge is dropped;
tone is carried by icon and colour.

- "Autonomous operating readiness needs review" / "Wake loop: Found 3 runtime
  items worth checking before broad autonomous runs." / "Fix Wake loop"
  -> "Not ready to run yet" / "3 things to check first." / "Check them"
- "Budget spend needs review" / "30d cost is $0.00 of $100.00 (0% used)."
  -> "Check spending" / "$0 of $100 used this month."
- "Review mode is on" / "Go live when ready"
  -> "Nothing is running" / "Safe to look around." / "Turn on"

**Board** — hide the filter bar (assignee / priority / search), project picker,
the three view toggles, and card age + priority chevron. Keep title, + New, all
seven columns, cards, and drag. Columns are *not* remapped: drag-and-drop has
regressed once before and lane folding would move drop targets.

**Inbox** — collapse four filter chips + agent select + three icon buttons to
"Needs you / All".

**New issue** — hide "Use a structured template"; reword "Queue after creating /
Add enough detail to make the brief ready." to "Start right away".

**Issue** — "Ready to run." -> "Ready"; "Queue focused dispatch" -> "Start now";
"SETUP NEEDED / Runtime command / Fix before dispatch." -> "Needs setup — pick
how this agent runs."

**Projects** — hide the `PORTFOLIO · 1 ACTIVE` eyebrow; "No repository
configured" -> "No code repo yet".

**Team** — hide the `ROSTER · 0 RUNNING NOW` eyebrow and per-row `0/1` / `1 free`
capacity meta; four stat cards drop to two (Working now / Needs attention).

**Operations** — keep the state card and the "next move" list with plain copy;
hide "Review service gates", Delegated Work Queue, and Recent Runtime Failures.
"Enable autonomous dispatch" / "Restart with the required launch env when you are
ready for agents to pick up queued work." -> "Turn the team on" / "Needs a
restart with the launch settings."

**Budgets** — hide the `SPEND GUARDRAILS` eyebrow; "Guardrails" -> "Limits";
"No spend guardrails yet" / "Create a company budget before broad autonomous runs
so provider spend has a hard stop." -> "No spending limit yet" / "Set one so the
team can't overspend."

## Flow

Home's "Needs you" cards are the entire to-do list. The fix is that no simple-mode
card lands on a console any more: Operations and Budgets get the same treatment,
so the path is Home -> one plain card -> one plain page -> done.

## Verification

- Advanced-mode screenshots of all nine in-scope pages captured before the change
  and re-captured after; they must be pixel-identical.
- `mix test` green.
- `test/cympho_web/live/simple_mode_copy_test.exs` asserts both variants render on
  each page, so a future edit that drops one side fails loudly.
