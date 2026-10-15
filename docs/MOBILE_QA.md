# Mobile QA & Responsive Layout Guide

Cympho is designed for full mobile responsiveness, enabling operators to manage autonomous companies, review pull requests, approve governance requests, and monitor agent swarms directly from modern mobile devices.

---

## 1. Responsive Architecture & Breakpoints

Cympho uses a responsive two-tier layout system styled via Tailwind CSS:

### 1.1 Breakpoint Threshold (`lg`: 1024px)
- **Desktop (`>= 1024px`)**:
  - Displays the persistent left Navigation Rail (`CymphoWeb.Components.NavRail`).
  - Multi-column layouts (three-column issue views, kanban swimlanes, side-by-side prompt inspector).
  - Keyboard navigation shortcuts active (`U` for mode toggle, `V` for density switch, `G D` for docs).
- **Mobile (`< 1024px`)**:
  - Desktop sidebar collapses into a slide-over mobile drawer (`#mobile-drawer`).
  - Fixed mobile top bar displays the active company switcher and hamburger toggle.
  - Fixed mobile bottom navigation (`#mobile-nav`) provides instant touch access to core destinations: Home (`/dashboard`), Tasks (`/issues`), New (`/issues/new`), Inbox (`/inbox`), and Team (`/agents`).
  - Complex multi-column views collapse into stacked, touch-scrollable panes.

### 1.2 Viewport Primitives & Safe Areas
Mobile web browsers (especially iOS Safari and Android Chrome) dynamically show/hide URL bars and toolbars. Cympho prevents layout jitter and button occlusion using CSS dynamic viewport units and safe-area environment variables:
- **Dynamic Viewport Height**: Uses `100dvh` rather than `100vh` to track dynamic browser address bars.
- **Kanban Board Geometry**: Uses `.mobile-board-height`:
  ```css
  height: calc(100dvh - var(--mobile-header-height) - var(--mobile-shell-bottom));
  ```
  Ensures board column cards scroll cleanly without being clipped by the bottom navigation bar.
- **Sticky Actions**: Form action bars (such as **Create Issue** or **Hire Agent**) use `.sticky-above-mobile-nav`:
  ```css
  bottom: calc(var(--mobile-nav-offset) + env(safe-area-inset-bottom, 0px));
  ```
  This ensures action buttons remain fixed above the navigation bar instead of sitting hidden underneath it (`bottom: 0`).
- **Scroll Padding**: The main scroll container defines `scroll-padding-bottom: 64px` so focusing inputs never hides them under the mobile navigation bar when virtual keyboards open.

---

## 2. Navigation Drawer Mechanics

### 2.1 Drawer States & Interaction
The mobile drawer provides access to secondary navigation destinations (Projects, Goals, Routines, Workspaces, Settings Hub, Approvals):
1. **Trigger**: Tapping the hamburger menu icon in the top header opens the drawer.
2. **Backdrop**: An overlay backdrop (`z-40`, semi-transparent) blurs the content behind the drawer. Tapping the backdrop or pressing `Escape` dismisses the drawer.
3. **Drawer Panel**: Slides in from the left (`x=0..256px`, `z-50`) without creating document-level horizontal scroll overflow.
4. **Active Route Highlights**: The currently active route is highlighted with high-contrast text and a left accent border.

---

## 3. Repeatable Mobile QA Verification Matrix

When making template or layout modifications, verify responsiveness across this standard viewport matrix (using Ego Lite or Chrome DevTools Device Mode).

### 3.1 Scenario 1: Standard Portrait (390x844 px)
- **Viewport**: 390px width by 844px height (iPhone 12/13/14 standard).
- **Checklist**:
  1. Navigate to `/onboarding`. Verify that both **Start a company** and **Improve this company** cards fit within the 390px content width with no horizontal overflow.
  2. Verify that `document.documentElement.scrollWidth === document.documentElement.clientWidth === 390`.
  3. Verify that `#mobile-nav` is fixed at the bottom (`y=780..844px`) and all 5 icon targets are tap-reachable.
  4. Navigate to `/kanban`. Verify that the columns scroll horizontally without causing the top header or bottom nav to pan. Verify column cards scroll vertically inside their containers.
  5. Navigate to `/issues/new`. Scroll to the bottom and verify that the submit button sits visibly above `#mobile-nav`.

### 3.2 Scenario 2: Virtual Keyboard Resize (390 x 500 px)
- **Simulation**: Focus an input field in portrait mode to trigger keyboard viewport reduction.
- **Checklist**:
  1. Open `/issues/new` or the Improve Company form (`/onboarding`).
  2. Focus the title text input.
  3. Reduce the viewport height to 500px.
  4. Verify the focused input remains fully visible in the active viewport.
  5. Scroll down to the primary action button. Verify it can be scrolled fully into view above the fixed navigation without being clipped.

### 3.3 Scenario 3: Landscape Mode (844 x 390 px)
- **Viewport**: 844px width by 390px height.
- **Checklist**:
  1. Verify the layout stays in mobile landscape mode (since width `844px < 1024px`).
  2. Open the navigation drawer and verify it takes up at most 256px width, leaving the remainder visible as a dim backdrop.
  3. Navigate to `/inbox`. Verify that attention cards wrap cleanly without truncating text or overflowing.

---

## 4. Automated Component Tests

In addition to manual smoke tests, automated ExUnit tests verify mobile markup and class contracts:

```bash
mix test test/cympho_web/components/mobile_shell_test.exs
```

These assertions verify that:
- Navigation drawer markup and ARIA attributes are present.
- Sticky action bars include `.sticky-above-mobile-nav`.
- Mobile navigation bar links point to valid canonical routes (`/dashboard`, `/issues`, `/issues/new`, `/inbox`, `/agents`).
