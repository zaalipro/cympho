# Mobile QA

This checklist records the repeatable mobile shell smoke test for Cympho. It complements the markup assertions in `test/cympho_web/components/mobile_shell_test.exs`; it does not replace physical-device testing.

## Recorded run

- Date: 2026-07-30
- Browser: Ego Lite only
- App: local Phoenix development server
- Authenticated role: owner of an existing company
- Interface coverage: Simple and Advanced modes, Compact and Detailed inbox density

### Desktop control

At 1440x900, `/onboarding` showed both plain-language choices: **Start a company** and **Improve this company**. The Improve path showed one goal field, optional context, and the **Create improvement** action. `/inbox` showed the company budget warning; Simple mode hid its technical details, while Advanced + Detailed showed the redacted policy/spend diagnostic. No horizontal overflow was present.

### 390x844 portrait

The test used a 390x844 Ego Lite viewport.

- `/onboarding` kept both choices within the 390px content width. The Start card occupied x=41..341 and the Improve card occupied x=41..341.
- The fixed mobile navigation occupied x=0..390 and y=787..844. Home, Board, New, Inbox, and Team remained available.
- Opening the navigation drawer placed it at x=0..256 without creating document-level horizontal overflow.
- The Improve form kept its title input, context field, and both actions inside x=41..341. The primary action was above the mobile navigation in the full portrait viewport.
- `/inbox?agent_id=all&density=detailed` kept the budget-warning action reachable. Simple mode hid `[data-testid="owner-attention-diagnostic"]`; Advanced mode displayed it. The diagnostic wrapped in its 265px content box (`scrollWidth == clientWidth`) and no actionable control extended beyond the viewport.
- `document.documentElement.scrollWidth == document.documentElement.clientWidth`; the bottom navigation also had `scrollWidth == clientWidth`.
- **Board geometry (G11 residual):** `/kanban` uses `.mobile-board-height` → `calc(100dvh - var(--mobile-header-height) - var(--mobile-shell-bottom))` so the board ends above `#mobile-nav`. At 390x844 with zero emulated safe-area, that is `844 - 64 - 64 = 716px` of board height; column cards scroll inside that box so the last card’s bottom edge stays above the nav top (y≈787).
- **New Issue sticky CTA:** `/issues/new` submit bar uses `.sticky-above-mobile-nav` → `bottom: var(--mobile-nav-offset)` (`3.5rem` + safe-area). At 390x844 the sticky bar clears the fixed nav instead of sitting under it (`bottom-0`).

### keyboard resize

The Improve title input was focused at 390px wide, then the Ego Lite viewport was reduced from 844px to 500px to simulate a keyboard-open layout.

- The focused `company[goal_title]` field stayed active and fully visible at y=352..390.
- The shell reported `scroll-padding-bottom: 64px`.
- Scrolling **Create improvement** into view placed it at y=392..436, while the fixed mobile navigation began at y=443. The action was fully usable and unobscured.
- The viewport retained zero document-level horizontal overflow.

This check originally exposed the action beneath the fixed navigation. Adding mobile shell scroll padding fixed the overlap; the figures above are from the post-fix rerun.

### landscape

The landscape check used an 844x390 Ego Lite viewport, which remains on the mobile shell below the 1024px breakpoint.

- The Improve page remained vertically scrollable with no document-level horizontal overflow.
- After scrolling the primary action into view, the title input was at y=62..100, **Create improvement** was at y=282..326, and the mobile navigation began at y=333.
- The onboarding content width matched the main scroll container (`scrollWidth == clientWidth == 836`).
- The detailed Inbox remained vertically scrollable, showed the owner-facing budget warning, and kept the bottom navigation at y=333..390 without horizontal overflow.

## Repeatable checklist

1. Open `/onboarding` in Ego Lite at 1440x900 and confirm both onboarding choices and the Improve form.
2. Switch to 390x844. Confirm `document.documentElement.scrollWidth <= document.documentElement.clientWidth`, open the drawer, and exercise the bottom navigation.
3. Open `/inbox?agent_id=all&density=detailed`. Toggle Simple and Advanced; confirm only Advanced shows the technical diagnostic and that its `scrollWidth <= clientWidth`.
4. Return to the Improve form, focus `input[name="company[goal_title]"]`, reduce the viewport to 390x500 to model a keyboard, and scroll the primary action into view. Its bottom edge must be above `#mobile-nav`'s top edge.
5. Switch to landscape at 844x390 and repeat the overflow and action-versus-navigation geometry checks.
6. Open `/kanban` at 390x844. Confirm `#kanban-board` uses `.mobile-board-height` (not `100vh-64px`), scroll the last column card into view, and verify its bottom edge is above `#mobile-nav`'s top edge.
7. Open `/issues/new` at 390x844. Confirm the sticky submit bar uses `.sticky-above-mobile-nav` and its bottom edge sits above `#mobile-nav` (not under it).

## Limits

Ego Lite's emulated viewports reported zero-valued hardware safe-area insets. The run verifies that the shell consumes the CSS safe-area variables and remains usable at the recorded dimensions; it does not prove behavior on every notched physical device or every third-party keyboard.
