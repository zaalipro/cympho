# Cympho Adaptive Flat UI Redesign

**Date:** 2026-07-12  
**Status:** Approved design  
**Scope:** Remaining UI flattening, anchored popovers, styled confirmations, issue-detail redesign, icon/tooltips, and dispatch-queue UX

## 1. Purpose

Cympho should feel like a premium autonomous-company operating system rather than a generic dashboard assembled from nested cards. The existing warm editorial design, terracotta accent, simple/advanced modes, and product functionality remain. This phase removes unnecessary visual containers, fixes interaction defects, and establishes reusable interaction primitives.

The central rule is:

> One visual container communicates one meaningful boundary.

Whitespace, typography, alignment, subtle background shifts, and hairline dividers establish hierarchy before borders or shadows. Cards remain only for repeated records, independent interactive objects, critical warnings, and true modal boundaries.

## 2. Product Modes

### 2.1 Compact / Simple Mode

Simple mode prioritizes decisions and primary actions.

- Keep essential identity, status, primary action, and current work.
- Replace dashboards of miniature cards with one summary row or instrument strip.
- Hide expert diagnostics, implementation metadata, raw payloads, and secondary configuration.
- Use generous spacing and plain-language labels.
- Preserve complete usability: simple mode may hide detail but cannot remove the only way to complete a primary workflow.

### 2.2 Advanced Mode

Advanced mode remains information-dense without becoming visually boxed.

- Preserve diagnostics, telemetry, runtime state, filters, and configuration.
- Use flat bands, split panes, tables, and labeled divider sections.
- Prefer compact icon controls and tabular data.
- Use a contextual side rail for secondary state rather than stacking cards inside the main content.
- Progressive disclosure is allowed for rarely used expert controls, but required operational state remains immediately visible.

## 3. Page Archetypes

### 3.1 Operational Console

Applies to Dashboard, Operations, Costs, Tool Traces, Kanban, and runtime-focused agent views.

Structure:

1. Compact command header: title, current operating state, primary action.
2. Flat horizontal instrument band: metrics separated by vertical hairlines.
3. Dominant working surface: queue, board, trace list, or runtime table.
4. Secondary diagnostic bands beneath or in a narrow rail.

Rules:

- Metric values are not individual cards.
- Filters live in one unboxed toolbar.
- Only repeated work records receive discrete surfaces.
- Status color is restrained and semantic.

### 3.2 Editorial Detail

Applies to Issue, Agent, Project, Goal, and Approval detail pages.

Structure:

1. Breadcrumb and strong identity header.
2. Main content column for description, work, timeline, and primary forms.
3. Narrow contextual rail for metadata, status, ownership, and secondary actions.
4. Sections separated by spacing and hairlines.

Rules:

- Long-form text is unboxed.
- Warnings are inline bands, not cards containing more cards.
- The rail uses compact rows; only critical blockers receive tinted surfaces.
- Repeated child records may remain cards or rows.

### 3.3 Calm Form

Applies to New/Edit Issue, Agent, Project, Goal, Settings, Integrations, Onboarding, and import/export.

Structure:

1. Clear page header and concise purpose statement.
2. One form canvas with semantic sections.
3. Sections separated by headings, spacing, and hairlines.
4. Optional sticky summary/checklist rail without nested framed cards.
5. Stable action footer with Cancel and primary submit.

Rules:

- Do not frame the form, then frame every section inside it.
- Helper text is inline and muted.
- Advanced fields use progressive disclosure.
- Confirmation/risk states are allowed distinct surfaces because they represent meaningful boundaries.

## 4. Anchored Popover System

### 4.1 Problem

Styled selects and date/time controls currently use fixed-position popovers with a coarse `flipThreshold`. The algorithm does not measure the rendered popover before choosing placement or clamp the final position against viewport bounds. Near the bottom or right edge, a menu can appear detached from its trigger.

### 4.2 Shared Primitive

All select, date, time, color, and future tooltip/popover controls use one shared positioning function.

On open:

1. Reveal the popover in a non-interactive measuring state (`visibility: hidden`, fixed positioning).
2. Measure trigger and popover rectangles.
3. Calculate available space above and below.
4. Prefer below when the full popover fits.
5. Otherwise choose above when it provides more usable space.
6. Cap the scrollable list height to available space, with a minimum usable height.
7. Re-measure after the height cap if necessary.
8. Clamp horizontal position to an 8 px viewport margin.
9. Clamp vertical position to an 8 px viewport margin.
10. Align the popover edge to the trigger edge; never position it near an unrelated field.

The popover remains `position: fixed` to escape overflow clipping. Position recomputes on capturing scroll and resize. It closes if its trigger leaves the DOM.

### 4.3 Behavioral Requirements

- Trigger and menu remain visually connected by a 4–6 px gap.
- Selected option scrolls into view after placement.
- Escape closes and returns focus to the trigger.
- Arrow keys, Home/End, typeahead, Enter, and Space remain supported.
- Clicking outside closes the popover.
- Only one popover may be open at a time.
- Mobile popovers may become bottom sheets only if the viewport is too narrow for a usable anchored menu; this phase defaults to anchored menus.

## 5. Styled Confirmation Dialog

### 5.1 Goal

No product action should invoke the browser-native `window.confirm` dialog. Existing `data-confirm` call sites remain declarative, but a global Cympho confirmation controller intercepts them before Phoenix HTML or LiveView handles the action.

### 5.2 Dialog Contract

The shared confirmation dialog includes:

- Context icon
- Short title derived from action tone or optional `data-confirm-title`
- Existing `data-confirm` message
- Cancel button
- Confirm button
- Neutral, warning, and destructive variants
- Optional confirm label via `data-confirm-label`

Behavior:

1. Intercept a click or submit whose actionable element/form has `data-confirm`.
2. Prevent propagation and default execution.
3. Open the styled dialog and retain the original action context.
4. On confirm, mark that context as confirmed for one replay only.
5. Replay the original click or form submission so existing `phx-click`, link methods, controller forms, and Phoenix bindings continue to work.
6. Clear the replay guard immediately.

Accessibility:

- `role="alertdialog"`, `aria-modal="true"`
- Title and description IDs
- Initial focus on Cancel for destructive actions; Confirm for safe neutral actions
- Tab focus trap
- Escape cancels
- Focus returns to the invoking control
- Background scrolling is locked while open
- Reduced-motion preference disables entrance motion

The system must not alter confirmation messages or business behavior at individual call sites.

## 6. Icon and Tooltip System

### 6.1 Icon-First Controls

Use icon-only controls where meaning is universally recognizable:

- Back
- Edit
- Copy
- Send
- Refresh
- Filter
- View switch
- Play/resume
- Pause
- Stop
- Archive
- Delete
- Overflow menu
- Expand/collapse

Keep visible text for ambiguous, high-consequence, or workflow-specific actions:

- Dispatch queue
- Request changes
- Approve and close
- Apply recommended patches
- Create project

These may pair text with an icon.

### 6.2 Status Indicators

Repeated statuses use a compact icon + semantic color. Visible text may be removed only when:

- The icon is unambiguous in context, and
- An accessible name and tooltip provide the full status.

High-level status summaries should retain visible text. Color never carries meaning alone.

### 6.3 Tooltip Primitive

A single reusable tooltip primitive handles icon controls and icon-only statuses.

Requirements:

- Appears on hover and keyboard focus after a short delay.
- Uses measured fixed positioning with viewport collision handling.
- Uses `role="tooltip"` and `aria-describedby`.
- Never traps pointer interaction.
- Closes on blur, pointer leave, Escape, or DOM removal.
- Tooltip text is concise and action-oriented.
- Native `title` may remain as a fallback but is not the primary experience.

## 7. Issue Detail Redesign

The issue-detail page is the first editorial-detail migration and the reference for later detail pages.

### 7.1 Header

- Breadcrumb: Issues → identifier.
- Large issue title.
- Compact status and priority indicators.
- Primary actions grouped at the right or in the contextual rail.
- Runtime top bar remains independent product chrome.

### 7.2 Main Column

Order:

1. Description, unboxed.
2. Delivery brief or execution brief, unboxed when healthy.
3. Missing-delivery-signal repair as one inline warning band with concise actions.
4. Evidence/work products and linked work.
5. Activity timeline and comment composer as the dominant workspace.

The repair scaffold may use a code surface because code-like content is a meaningful boundary, but that surface must not sit inside multiple framed containers.

### 7.3 Comment Composer

- Template actions become compact icon buttons with styled tooltips.
- The currently selected template is visibly highlighted.
- Textarea and Send remain the strongest interaction.
- Send uses an icon plus text on wide screens and icon-only with tooltip on narrow screens.

### 7.4 Contextual Rail

Compact rows for:

- Status
- Priority
- Assignee
- Due date
- Goal/mission
- Runtime state
- Created/updated timestamps

Blockers and setup needs:

- Normal setup items are compact status rows with icon, heading, and action.
- Critical blockers may use one tinted warning surface.
- Do not stack several full cards with borders and shadows.

The rail may be sticky on desktop and becomes an inline accordion or section below the main content on mobile.

## 8. Dispatch Queue Semantics

### 8.1 Navigation

“Dispatch queue” from an agent detail page must navigate to Issues with explicit query parameters:

- `assignee_id=<agent id>`
- queued dispatch statuses (the exact statuses use the domain’s existing queue definition rather than a new duplicate constant)
- optional `queue=dispatch` presentation hint

### 8.2 Issues Page Feedback

When a dispatch filter is active:

- Header/subtitle states that the page is showing that agent’s dispatch queue.
- Persistent filter chip displays agent name/avatar and queue status.
- Result count is visible.
- Clear action returns to All Issues.
- Empty state says the named agent has no queued dispatch work.

The server remains authoritative. The filter must be applied in `Issues.list_issues_paginated/1`, not merely represented visually.

## 9. Shared Flattening Primitives

Introduce or standardize these primitives instead of one-off class bundles:

- `section_header`: label, title, optional description/action; no containing card.
- `instrument_band`: horizontal metrics with internal hairline separators.
- `context_row`: label, value/control, optional icon; used in side rails.
- `flat_section`: spacing and optional top divider; no background or border by default.
- `warning_band`: one semantic boundary for actionable warnings.
- `icon_button`: accessible name, tone, size, tooltip.
- `tooltip`: global measured overlay.
- `confirm_dialog`: global action replay controller.

Existing `panel` and `card` components remain for meaningful independent objects. They are not the default section wrapper.

## 10. Page Migration Order

### Phase 1: Interaction Foundations

- Anchored popover algorithm
- Styled confirmation dialog
- Tooltip and icon-button primitives
- Component tests and browser interaction verification

### Phase 2: Reference Workflow

- Issue detail
- Comment composer
- Context rail
- Dispatch queue routing and filtered Issues state

### Phase 3: Dense Operational Pages

- Agent detail
- Operations
- Dashboard
- Costs
- Tool traces
- Kanban toolbar and command summary

### Phase 4: Calm Forms and Settings

- New/Edit Agent
- New/Edit Issue
- New/Edit Project
- Goal forms
- Settings integrations
- Onboarding and import/export

### Phase 5: Remaining Lists and Details

- Goals
- Projects
- Approvals/reviews
- Company/workspace/plugin/skill pages
- Remaining utility pages found by the visual audit

## 11. Responsive Behavior

- Below 768 px, all split layouts stack.
- Sticky rails become normal-flow sections.
- Toolbars allow horizontal scrolling or collapse secondary actions into overflow menus.
- Icon buttons retain at least 44×44 px touch targets.
- Popovers remain inside an 8 px viewport margin.
- Confirmation dialogs use nearly full width with 16 px page margins.
- No `100vh`; use `100dvh` where full-height behavior is required.

## 12. Testing and Verification

### Automated

- Unit tests for placement calculation with below, above, left-edge, right-edge, and small-viewport cases.
- Browser/DOM tests for select open, keyboard selection, outside click, scroll reposition, and focus return.
- Confirmation tests for LiveView click, link navigation, form submit, cancel, Escape, and destructive tone.
- LiveView tests for dispatch queue query handling, visible filter state, result filtering, clear action, and empty state.
- Existing LiveView/controller/full suites must remain green.

### Browser Verification

At desktop and mobile widths:

- Goal parent selector near viewport bottom.
- Project status selector near right edge.
- Date picker collision behavior.
- Runtime low-power/pause/stop confirmations.
- Issue delete/comment delete confirmations.
- Issue detail simple and advanced modes.
- Dispatch queue navigation with matching and empty results.
- Keyboard-only tooltip, select, and dialog flows.
- Reduced-motion mode.

### Completion Gate

- `mix format`
- `mix compile --warnings-as-errors`
- Tailwind and esbuild builds
- Focused component/LiveView tests
- Full `mix test`
- `git diff --check`
- Browser console free of new errors
- No native browser confirmation dialogs in audited product flows

## 13. Non-Goals

- Replacing Phoenix LiveView or Tailwind.
- Changing domain logic unrelated to queue filtering.
- Introducing a third UI mode.
- Replacing all text with icons.
- Rewriting every page at once without intermediate verification.
- Adding animation that obscures state or delays action completion.

## 14. Success Criteria

The redesign succeeds when:

- Popovers remain attached to their triggers at every viewport edge.
- Native confirmation dialogs no longer appear.
- Issue detail has one clear workspace and one quiet contextual rail.
- Dispatch Queue opens a visibly and actually filtered queue.
- Common icon controls have styled, accessible tooltips.
- Compact/simple mode is calm and immediately actionable.
- Advanced mode is dense but not a collection of nested cards.
- Remaining pages follow the same three archetypes and shared primitives.
- Existing workflows and tests remain intact.
