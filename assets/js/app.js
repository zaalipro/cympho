import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// Cympho ships dark-only per DESIGN.md. Theme toggle was removed; this
// noop preserves the global symbol so any stale inline handlers still in
// the wild don't throw before they're cleaned up.
window.toggleTheme = function() {};

const UI_MODE_KEY = "cympho-ui-mode";

function currentUIMode() {
  const domMode = document.documentElement.dataset.uiMode;
  if (domMode === "advanced" || domMode === "simple") return domMode;

  try {
    return localStorage.getItem(UI_MODE_KEY) === "advanced" ? "advanced" : "simple";
  } catch (_e) {
    return "simple";
  }
}

function writeUIMode(mode) {
  try {
    localStorage.setItem(UI_MODE_KEY, mode);
  } catch (_e) {
    /* storage disabled — the DOM attribute still applies for this session */
  }
}

function visibleModeControl(mode) {
  const controls = [
    ...document.querySelectorAll(`[data-ui-mode-option="${mode}"]`),
    ...document.querySelectorAll("[data-ui-mode-toggle]")
  ];

  return controls.find((control) => {
    if (!(control instanceof HTMLElement) || control.closest("[inert]")) return false;
    const style = window.getComputedStyle(control);
    const rect = control.getBoundingClientRect();
    return style.display !== "none" &&
      style.visibility !== "hidden" &&
      rect.width > 0 &&
      rect.height > 0 &&
      rect.bottom > 0 &&
      rect.right > 0 &&
      rect.top < window.innerHeight &&
      rect.left < window.innerWidth;
  });
}

function focusedElementIsVisible(element) {
  if (!(element instanceof HTMLElement) || element === document.body) return true;
  const style = window.getComputedStyle(element);
  return style.display !== "none" && style.visibility !== "hidden" && element.getClientRects().length > 0;
}

function applyUIMode(mode, persist = false) {
  const normalized = mode === "advanced" ? "advanced" : "simple";
  const activeLabel = normalized === "advanced" ? "Advanced" : "Simple";
  const nextLabel = normalized === "advanced" ? "Simple" : "Advanced";
  const focusedBeforeChange = document.activeElement;
  document.documentElement.dataset.uiMode = normalized;
  if (persist) writeUIMode(normalized);

  document.querySelectorAll("[data-ui-mode-toggle]").forEach((toggle) => {
    toggle.dataset.mode = normalized;
    toggle.setAttribute("aria-pressed", String(normalized === "advanced"));
    toggle.setAttribute("aria-label", `Switch to ${nextLabel} view`);
    toggle.setAttribute("title", `${activeLabel} view active. Switch to ${nextLabel} view (U)`);

    toggle.querySelectorAll("[data-ui-mode-label]").forEach((label) => {
      label.textContent = `Switch to ${nextLabel} view`;
    });

    toggle.querySelectorAll("[data-ui-mode-icon]").forEach((icon) => {
      icon.classList.toggle("hero-squares-2x2-mini", normalized !== "advanced");
      icon.classList.toggle("hero-adjustments-horizontal-mini", normalized === "advanced");
    });
  });

  document.querySelectorAll("[data-ui-mode-switch]").forEach((switcher) => {
    switcher.dataset.mode = normalized;
  });

  document.querySelectorAll("[data-ui-mode-option]").forEach((option) => {
    const active = option.dataset.uiModeOption === normalized;
    option.dataset.active = String(active);
    option.setAttribute("aria-pressed", String(active));
  });

  if (persist) {
    document.querySelectorAll("[data-ui-mode-status]").forEach((status) => {
      status.textContent = `${activeLabel} view enabled`;
    });
  }

  if (!focusedElementIsVisible(focusedBeforeChange)) {
    visibleModeControl(normalized)?.focus({preventScroll: true});
  }
}

function toggleUIMode() {
  applyUIMode(currentUIMode() === "advanced" ? "simple" : "advanced", true);
}

function shortcutTargetIsTextInput(target) {
  if (!target) return false;
  return target.tagName === 'INPUT' ||
    target.tagName === 'TEXTAREA' ||
    target.tagName === 'SELECT' ||
    target.isContentEditable;
}

function plainShortcut(e, key) {
  return e.key.toLowerCase() === key &&
    !e.metaKey &&
    !e.ctrlKey &&
    !e.altKey;
}

function toggleDensityView() {
  const switcher = document.querySelector("[data-density-switch]");
  if (!switcher) return false;

  const current = switcher.dataset.density === "detailed" ? "detailed" : "compact";
  const next = current === "detailed" ? "compact" : "detailed";
  const target = switcher.querySelector(`[data-density-option="${next}"]`);
  if (!target) return false;

  target.click();
  return true;
}

document.addEventListener("click", (e) => {
  const option = e.target.closest("[data-ui-mode-option]");
  if (option) {
    e.preventDefault();
    applyUIMode(option.dataset.uiModeOption, true);
    return;
  }

  const toggle = e.target.closest("[data-ui-mode-toggle]");
  if (!toggle) return;
  e.preventDefault();
  toggleUIMode();
});

applyUIMode(currentUIMode());

// Timeline scroll hook for chat-style auto-scroll
const TimelineScroll = {
  mounted() {
    this.el.addEventListener("phx:update", () => {
      this.maybeScrollToBottom();
    });
    this.maybeScrollToBottom();

    // Track scroll position
    this.el.addEventListener("scroll", () => {
      const isAtBottom = this.el.scrollTop + this.el.clientHeight >= this.el.scrollHeight - 50;
      // Optional: push scroll position to server if needed
      // this.pushEvent("scroll_position", {is_at_bottom: isAtBottom});
    });
  },

  maybeScrollToBottom() {
    // Only auto-scroll if already near bottom or on initial load
    const isAtBottom = this.el.scrollTop + this.el.clientHeight >= this.el.scrollHeight - 100;
    if (isAtBottom || this.el.scrollTop === 0) {
      this.el.scrollTop = this.el.scrollHeight;
    }
  }
};

// Infinite scroll: a sentinel rendered after a streamed list. When it nears the
// scroll viewport (rootMargin prefetch) it fires a LiveView event ("next-page"
// by default). The scroll container is `#main-content` (the window itself does
// not scroll), so we observe against it rather than the viewport. A `pending`
// guard, cleared when the server replies, keeps it to one fire per round-trip.
// At the end of the feed the server stops rendering the sentinel, which
// disconnects the observer.
const InfiniteScroll = {
  mounted() {
    this.pending = false;
    const eventName = this.el.dataset.event || "next-page";
    const rootMargin = this.el.dataset.rootMargin || "500px 0px";
    const root =
      this.el.closest("[data-infinite-scroll-root]") ||
      document.getElementById("main-content") ||
      null;

    this.observer = new IntersectionObserver(
      (entries) => {
        if (!entries[0] || !entries[0].isIntersecting) return;
        if (this.el.dataset.hasMore === "false" || this.pending) return;
        this.pending = true;
        const done = () => { this.pending = false; };
        const target = this.el.dataset.target;
        if (target) {
          this.pushEventTo(target, eventName, {}, done);
        } else {
          this.pushEvent(eventName, {}, done);
        }
      },
      {root, rootMargin, threshold: 0}
    );

    this.observer.observe(this.el);
  },

  destroyed() {
    if (this.observer) this.observer.disconnect();
    this.observer = null;
  }
};

// Toast notification hook
const Toast = {
  _queue: [],
  _activeToasts: [],
  _rateLimitMap: {},
  _RATE_LIMIT_MS: 3000,
  _MAX_ACTIVE: 5,
  _DISMISS_MS: 5000,

  mounted() {
    this.handleEvent("toast", ({message, type, key}) => {
      if (!this._rateLimited(key || message)) {
        this._enqueue(message, type || "info");
      }
    });
  },

  _rateLimited(key) {
    if (!key) return false;
    const now = Date.now();
    const lastShown = this._rateLimitMap[key];
    if (lastShown && now - lastShown < this._RATE_LIMIT_MS) return true;
    this._rateLimitMap[key] = now;
    return false;
  },

  _enqueue(message, type) {
    this._queue.push({message, type});
    this._renderNext();
  },

  _renderNext() {
    if (this._activeToasts.length >= this._MAX_ACTIVE || this._queue.length === 0) return;
    const {message, type} = this._queue.shift();
    const container = document.getElementById("toast-container");
    if (!container) return;
    const el = document.createElement("div");
    el.className = `toast toast-${type}`;
    el.textContent = message;
    container.appendChild(el);
    requestAnimationFrame(() => el.classList.add("toast-visible"));
    const id = setTimeout(() => this._dismiss(el), this._DISMISS_MS);
    this._activeToasts.push({el, id});
  },

  _dismiss(el) {
    el.classList.remove("toast-visible");
    el.classList.add("toast-exit");
    setTimeout(() => {
      el.remove();
      this._activeToasts = this._activeToasts.filter(t => t.el !== el);
      this._renderNext();
    }, 300);
  }
};

// Kanban drag-and-drop hook with optimistic updates.
//
// SortableJS moves the card to the destination column on drop. We then push
// `transition_issue` to the server. On confirm, we just clear the pending
// flag — the server's render already matches. On rollback, we move the card
// back to its source column and animate a shake.
const KanbanSortable = {
  mounted() {
    this.sortables = [];
    this._initSortables();

    this.handleEvent("shake_card", ({issue_id}) => {
      const card = this._findCard(issue_id);
      if (card) {
        card.classList.add("phx-error-shake");
        setTimeout(() => card.classList.remove("phx-error-shake"), 600);
      }
    });

    this.handleEvent("kanban:confirm", ({issue_id}) => {
      const card = this._findCard(issue_id);
      if (!card) return;
      card.removeAttribute("data-pending");
      card.classList.add("kanban-card-confirmed");
      setTimeout(() => card.classList.remove("kanban-card-confirmed"), 200);
    });

    this.handleEvent("kanban:rollback", ({issue_id, to_status}) => {
      const card = this._findCard(issue_id);
      if (!card) return;
      const targetColumn = this.el.querySelector(`[data-kanban-column="${to_status}"]`);
      if (targetColumn) targetColumn.appendChild(card);
      card.removeAttribute("data-pending");
    });
  },

  _findCard(issueId) {
    return this.el.querySelector(`[data-issue-id="${issueId}"]`);
  },
  updated() {
    this.sortables.forEach(s => s.destroy());
    this.sortables = [];
    this._initSortables();
  },
  destroyed() {
    this.sortables.forEach(s => s.destroy());
  },
  _initSortables() {
    const hook = this;
    if (typeof window.Sortable !== "function") {
      this.el.dataset.dragUnavailable = "true";
      return;
    }

    this.el.dataset.dragUnavailable = "false";
    const columns = this.el.querySelectorAll("[data-kanban-column]");
    columns.forEach(column => {
      try {
        const sortable = new window.Sortable(column, {
          group: "kanban",
          draggable: "[data-kanban-card]",
          ghostClass: "opacity-30",
          dragClass: "rotate-2",
          animation: 150,
          filter: "button, input, textarea, select, details, [data-no-drag]",
          preventOnFilter: false,
          // Refuse invalid columns client-side using the SM-backed allow-list
          // rendered on each card. Server still validates; this avoids the
          // flash/rollback dance for known-invalid drops.
          onMove(evt) {
            const toStatus = evt.to && evt.to.dataset && evt.to.dataset.kanbanColumn;
            const fromStatus = evt.from && evt.from.dataset && evt.from.dataset.kanbanColumn;
            if (!toStatus || !fromStatus || fromStatus === toStatus) return true;
            const allowed = (evt.dragged.dataset.allowedStatuses || "")
              .split(",")
              .map((s) => s.trim())
              .filter(Boolean);
            // Empty allow-list (terminal with no reopen encoding) refuses all
            // cross-column moves; non-empty must include the target.
            if (allowed.length === 0) return false;
            return allowed.includes(toStatus);
          },
          onStart(evt) {
            evt.item.classList.add("kanban-card-dragging");
          },
          onEnd(evt) {
            evt.item.classList.remove("kanban-card-dragging");
            const issueId = evt.item.dataset.issueId;
            const toStatus = evt.to.dataset.kanbanColumn;
            const fromStatus = evt.from.dataset.kanbanColumn;
            if (fromStatus === toStatus) return;
            const allowed = (evt.item.dataset.allowedStatuses || "")
              .split(",")
              .map((s) => s.trim())
              .filter(Boolean);
            if (allowed.length > 0 && !allowed.includes(toStatus)) {
              // Safety net if onMove was bypassed; put the card back.
              if (evt.from) evt.from.appendChild(evt.item);
              return;
            }
            // Mark the card pending so any incoming LiveView render knows
            // we're awaiting confirmation.
            evt.item.setAttribute("data-pending", "true");
            hook.pushEvent("transition_issue", {id: issueId, to_status: toStatus});
          }
        });
        this.sortables.push(sortable);
      } catch (_error) {
        this.el.dataset.dragUnavailable = "true";
      }
    });
  }
};

// Active navigation highlighting
function highlightActiveNav() {
  const path = window.location.pathname;

  // Sidebar nav items
  document.querySelectorAll('.nav-item[data-nav-path]').forEach(el => {
    const navPath = el.dataset.navPath;
    const navPaths = [navPath, ...(el.dataset.navMatches || '').split(',').filter(Boolean)];
    const isActive = navPaths.some(candidate => path === candidate || path.startsWith(candidate + '/'));
    el.setAttribute('data-active', isActive ? 'true' : 'false');
    if (isActive) {
      el.setAttribute('aria-current', 'page');
    } else {
      el.removeAttribute('aria-current');
    }
  });

  // Mobile bottom nav
  document.querySelectorAll('.mobile-nav-item[data-mobile-nav-path]').forEach(el => {
    const navPath = el.dataset.mobileNavPath;
    const navPaths = [navPath, ...(el.dataset.navMatches || '').split(',').filter(Boolean)];
    const isActive = navPaths.some(candidate => path === candidate || path.startsWith(candidate + '/'));
    el.setAttribute('data-active', isActive ? 'true' : 'false');
  });
}

// Command palette search filter
function initCommandPalette() {
  const input = document.getElementById('command-input');
  const results = document.getElementById('command-results');
  const palette = document.getElementById('command-palette');
  if (!input || !results) return;

  input.addEventListener('input', (e) => {
    const query = e.target.value.toLowerCase().trim();
    const items = results.querySelectorAll('.command-item');

    items.forEach(item => {
      const text = item.textContent.toLowerCase();
      item.style.display = !query || text.includes(query) ? '' : 'none';
    });
  });

  // Close on backdrop click
  if (palette) {
    palette.addEventListener('click', (e) => {
      if (e.target === palette) {
        palette.classList.add('hidden');
      }
    });
  }
}

function resetCommandPalette(input) {
  if (!input) return;
  input.value = '';
  input.dispatchEvent(new Event('input'));
  requestAnimationFrame(() => input.focus());
}

function openCommandPalette() {
  const palette = document.getElementById('command-palette');
  if (!palette) return;

  palette.classList.remove('hidden');
  resetCommandPalette(document.getElementById('command-input'));
}

// Keyboard shortcuts
const GOTO_KEYS = {
  'i': '/issues',
  'p': '/projects',
  'k': '/kanban',
  'a': '/agents',
  'g': '/goals',
  'd': '/dashboard',
  's': '/settings/profile',
};

const ADVANCED_ONLY_GOTO_KEYS = new Set(['i', 'g']);

let gotoBuffer = '';
let gotoTimer = null;

function handleKeydown(e) {
  const target = e.target;
  const isInput = shortcutTargetIsTextInput(target);

  // Escape always closes modals
  if (e.key === 'Escape') {
    const palette = document.getElementById('command-palette');
    const shortcuts = document.getElementById('shortcuts-modal');
    const quickCreate = document.getElementById('quick-create-modal');
    if (quickCreate && !quickCreate.classList.contains('hidden')) {
      quickCreate.classList.add('hidden');
      return;
    }
    if (palette && !palette.classList.contains('hidden')) {
      palette.classList.add('hidden');
      return;
    }
    if (shortcuts && !shortcuts.classList.contains('hidden')) {
      shortcuts.classList.add('hidden');
      return;
    }
    return;
  }

  // Cmd/Ctrl+K opens command palette
  if ((e.metaKey || e.ctrlKey) && e.key === 'k' && !e.shiftKey) {
    e.preventDefault();
    const palette = document.getElementById('command-palette');
    if (palette) {
      if (palette.classList.contains('hidden')) openCommandPalette();
      else palette.classList.add('hidden');
    }
    return;
  }

  // Cmd/Ctrl+Shift+K opens company switcher
  if ((e.metaKey || e.ctrlKey) && e.key === 'K') {
    e.preventDefault();
    if (window.openCompanySwitcher) {
      window.openCompanySwitcher();
    }
    return;
  }

  // Plain-key shortcuts must not fire while the user is typing. Modified
  // command shortcuts above remain globally available from form fields.
  if (isInput) return;

  // ? opens shortcuts cheatsheet
  if (e.key === '?' || (e.shiftKey && e.key === '/')) {
    e.preventDefault();
    const modal = document.getElementById('shortcuts-modal');
    if (modal) modal.classList.toggle('hidden');
    return;
  }

  // C opens the quick-create modal — ignore when held with Cmd/Ctrl/Alt
  // (Cmd+C is copy and must always reach the browser).
  if (e.key === 'c' && !e.metaKey && !e.ctrlKey && !e.altKey) {
    e.preventDefault();
    openQuickCreate();
    return;
  }

  if (gotoBuffer === 'g') {
    const key = e.key.toLowerCase();
    const url = GOTO_KEYS[key];
    const availableInCurrentMode =
      currentUIMode() === 'advanced' || !ADVANCED_ONLY_GOTO_KEYS.has(key);

    if (url && availableInCurrentMode) {
      e.preventDefault();
      window.location.href = url;
    }
    gotoBuffer = '';
    clearTimeout(gotoTimer);
    return;
  }

  // G prefix for navigation (G then another key)
  if (e.key.toLowerCase() === 'g' && !e.metaKey && !e.ctrlKey) {
    gotoBuffer = 'g';
    clearTimeout(gotoTimer);
    gotoTimer = setTimeout(() => { gotoBuffer = ''; }, 1000);
    return;
  }

  if (plainShortcut(e, 'v') && toggleDensityView()) {
    e.preventDefault();
    return;
  }

  if (plainShortcut(e, 'u')) {
    e.preventDefault();
    toggleUIMode();
    return;
  }
}

// Company switcher
function initCompanySwitcher() {
  const wrapper = document.getElementById('company-switcher-wrapper');
  if (!wrapper) return;

  const modal = document.getElementById('company-switcher-modal');
  const searchInput = document.getElementById('company-switcher-search');
  const resultsList = document.getElementById('company-switcher-list');
  const emptyState = document.getElementById('company-switcher-empty');
  const companies = JSON.parse(wrapper.dataset.companies || '[]');
  const currentCompanyId = wrapper.dataset.currentCompanyId;

  function companyInitials(name) {
    return name
      .split(/\s+/)
      .slice(0, 2)
      .map(word => word[0])
      .join('')
      .toUpperCase();
  }

  function renderCompanyList(filter = '') {
    const filtered = companies.filter(c =>
      c.name.toLowerCase().includes(filter.toLowerCase())
    );

    if (filtered.length === 0) {
      while (resultsList.firstChild) {
        resultsList.removeChild(resultsList.firstChild);
      }
      emptyState.classList.remove('hidden');
      return;
    }

    emptyState.classList.add('hidden');
    while (resultsList.firstChild) {
      resultsList.removeChild(resultsList.firstChild);
    }

    filtered.forEach(company => {
      const isCurrent = company.id === currentCompanyId;

      const item = document.createElement('div');
      item.className = `flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm cursor-pointer transition-colors ${isCurrent ? 'bg-surface-hover text-text-primary' : 'text-text-secondary hover:bg-surface-hover hover:text-text-primary'}`;
      item.dataset.companyId = company.id;

      const logoDiv = document.createElement('div');
      logoDiv.className = 'w-8 h-8 rounded-lg overflow-hidden flex items-center justify-center shrink-0 bg-brand/10';

      if (company.logo_url) {
        const img = document.createElement('img');
        img.src = company.logo_url;
        img.alt = company.name;
        img.className = 'w-full h-full object-cover';
        logoDiv.appendChild(img);
      } else {
        const span = document.createElement('span');
        span.className = 'text-sm font-590 text-brand';
        span.textContent = companyInitials(company.name);
        logoDiv.appendChild(span);
      }

      const infoDiv = document.createElement('div');
      infoDiv.className = 'flex-1 min-w-0';

      const nameDiv = document.createElement('div');
      nameDiv.className = 'font-510 truncate';
      nameDiv.textContent = company.name;
      infoDiv.appendChild(nameDiv);

      if (isCurrent) {
        const currentDiv = document.createElement('div');
        currentDiv.className = 'text-xs text-text-quaternary';
        currentDiv.textContent = 'Current company';
        infoDiv.appendChild(currentDiv);
      }

      item.appendChild(logoDiv);
      item.appendChild(infoDiv);

      if (isCurrent) {
        const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('class', 'w-4 h-4 text-brand shrink-0');
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('viewBox', '0 0 24 24');

        const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
        path.setAttribute('stroke-linecap', 'round');
        path.setAttribute('stroke-linejoin', 'round');
        path.setAttribute('stroke-width', '2');
        path.setAttribute('d', 'M5 13l4 4L19 7');

        svg.appendChild(path);
        item.appendChild(svg);
      }

      item.addEventListener('click', () => {
        const companyId = company.id;
        const returnTo = encodeURIComponent(window.location.pathname);
        window.location.href = `/switch-company/${companyId}?return_to=${returnTo}`;
      });

      resultsList.appendChild(item);
    });
  }

  function openModal() {
    modal.classList.remove('hidden');
    searchInput.value = '';
    searchInput.focus();
    renderCompanyList('');
  }

  function closeModal() {
    modal.classList.add('hidden');
  }

  // Search input handler
  searchInput.addEventListener('input', (e) => {
    renderCompanyList(e.target.value);
  });

  // Click outside to close
  modal.addEventListener('click', (e) => {
    if (e.target === modal) {
      closeModal();
    }
  });

  // Escape to close
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !modal.classList.contains('hidden')) {
      closeModal();
    }
  });

  // Expose open function globally
  window.openCompanySwitcher = openModal;
}

// Org chart export hook
const OrgChartExport = {
  mounted() {
    this.handleEvent("export_svg", () => {
      this.exportToSVG();
    });
  },

  exportToSVG() {
    const orgChartContainer = document.querySelector("#org-chart-export-area");
    if (!orgChartContainer) {
      console.error("Org chart container not found");
      return;
    }

    // Get the computed styles
    const width = orgChartContainer.offsetWidth;
    const height = orgChartContainer.offsetHeight;

    // Create SVG element
    const svgNS = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(svgNS, "svg");
    svg.setAttribute("width", width);
    svg.setAttribute("height", height);
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);

    // Create foreignObject to embed HTML
    const foreignObject = document.createElementNS(svgNS, "foreignObject");
    foreignObject.setAttribute("width", "100%");
    foreignObject.setAttribute("height", "100%");

    // Clone the org chart content
    const clonedContent = orgChartContainer.cloneNode(true);
    foreignObject.appendChild(clonedContent);
    svg.appendChild(foreignObject);

    // Serialize to string
    const serializer = new XMLSerializer();
    const svgString = serializer.serializeToString(svg);

    // Create download link
    const blob = new Blob([svgString], { type: "image/svg+xml" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `org-chart-${new Date().toISOString().split("T")[0]}.svg`;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  }
};

// Searchable combobox / multi-select. Pairs with
// CymphoWeb.Components.Combobox. Manages: open/close on trigger click,
// outside-click close, search filtering, keyboard nav (↑/↓/Enter/Esc),
// and selection. Pushes the configured event with `%{selected: [ids]}`
// (multi) or `%{selected: id | nil}` (single) when the user picks.
const Combobox = {
  mounted() {
    this.multi = this.el.dataset.comboboxMulti === "true";
    this.eventName = this.el.dataset.comboboxOnchange;
    this.trigger = this.el.querySelector("[data-combobox-trigger]");
    this.popover = this.el.querySelector("[data-combobox-popover]");
    this.search = this.el.querySelector("[data-combobox-search]");
    this.list = this.el.querySelector("[data-combobox-list]");
    this.empty = this.el.querySelector("[data-combobox-empty]");
    this.clearBtn = this.el.querySelector("[data-combobox-clear]");
    this.activeIdx = -1;

    this.trigger.addEventListener("click", (e) => {
      e.stopPropagation();
      this._toggle();
    });

    this.list.addEventListener("click", (e) => {
      const opt = e.target.closest("[data-combobox-option]");
      if (!opt) return;
      this._toggleSelection(opt.dataset.comboboxId);
      if (!this.multi) this._close();
    });

    if (this.search) {
      this.search.addEventListener("input", () => this._filter(this.search.value));
      this.search.addEventListener("keydown", (e) => this._onKeydown(e));
    }
    this.trigger.addEventListener("keydown", (e) => this._onKeydown(e));

    if (this.clearBtn) {
      this.clearBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        this._clear();
      });
    }

    this._docClick = (e) => {
      if (!this.el.contains(e.target)) this._close();
    };
    document.addEventListener("click", this._docClick);
  },
  destroyed() {
    document.removeEventListener("click", this._docClick);
  },
  _toggle() {
    if (this.popover.classList.contains("hidden")) this._open();
    else this._close();
  },
  _open() {
    this.popover.classList.remove("hidden");
    this.trigger.setAttribute("aria-expanded", "true");
    this.activeIdx = -1;
    if (this.search) {
      this.search.value = "";
      this._filter("");
      requestAnimationFrame(() => this.search.focus());
    }
  },
  _close() {
    this.popover.classList.add("hidden");
    this.trigger.setAttribute("aria-expanded", "false");
    this._clearActive();
  },
  _filter(query) {
    const q = query.trim().toLowerCase();
    let visible = 0;
    this._visibleOptions().forEach(opt => opt.removeAttribute("data-combobox-hidden"));
    this.list.querySelectorAll("[data-combobox-option]").forEach((opt) => {
      const label = (opt.dataset.comboboxLabel || "").toLowerCase();
      const match = !q || label.includes(q);
      opt.style.display = match ? "" : "none";
      if (match) visible++;
    });
    if (this.empty) this.empty.classList.toggle("hidden", visible > 0);
    this.activeIdx = -1;
    this._clearActive();
  },
  _visibleOptions() {
    return Array.from(this.list.querySelectorAll("[data-combobox-option]"))
      .filter(opt => opt.style.display !== "none");
  },
  _onKeydown(e) {
    if (e.key === "Escape") {
      e.preventDefault();
      this._close();
      this.trigger.focus();
      return;
    }
    if (this.popover.classList.contains("hidden")) {
      if (e.key === "ArrowDown" || e.key === "Enter") {
        e.preventDefault();
        this._open();
      }
      return;
    }
    const opts = this._visibleOptions();
    if (e.key === "ArrowDown") {
      e.preventDefault();
      this.activeIdx = Math.min(this.activeIdx + 1, opts.length - 1);
      this._highlight(opts);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      this.activeIdx = Math.max(this.activeIdx - 1, 0);
      this._highlight(opts);
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (this.activeIdx >= 0 && opts[this.activeIdx]) {
        this._toggleSelection(opts[this.activeIdx].dataset.comboboxId);
        if (!this.multi) this._close();
      }
    }
  },
  _highlight(opts) {
    this._clearActive();
    const target = opts[this.activeIdx];
    if (target) {
      target.setAttribute("data-combobox-active", "true");
      target.scrollIntoView({block: "nearest"});
    }
  },
  _clearActive() {
    this.list.querySelectorAll("[data-combobox-active]").forEach(el => el.removeAttribute("data-combobox-active"));
  },
  _currentSelection() {
    return Array.from(this.list.querySelectorAll('[data-combobox-selected="true"]'))
      .map(el => el.dataset.comboboxId);
  },
  _toggleSelection(id) {
    let selected = this._currentSelection();
    if (this.multi) {
      selected = selected.includes(id) ? selected.filter(x => x !== id) : [...selected, id];
    } else {
      selected = selected.includes(id) ? [] : [id];
    }
    this._push(selected);
  },
  _clear() {
    this._push([]);
    this._close();
  },
  _push(selectedIds) {
    const payload = this.multi
      ? {selected: selectedIds}
      : {selected: selectedIds[0] || null};
    this.pushEventTo(this.el, this.eventName, payload);
  }
};

// User menu popover at the bottom of the sidebar.
const UserMenu = {
  mounted() {
    this.trigger = this.el.querySelector('[data-user-menu-trigger]');
    this.popover = this.el.querySelector('[data-user-menu-popover]');
    if (!this.trigger || !this.popover) return;

    this.toggle = (e) => {
      e.stopPropagation();
      const isOpen = !this.popover.classList.contains('hidden');
      this._setOpen(!isOpen);
    };

    this.outside = (e) => {
      if (!this.el.contains(e.target)) this._setOpen(false);
    };

    this.escape = (e) => {
      if (e.key === 'Escape') this._setOpen(false);
    };

    this.handleAction = (e) => {
      const item = e.target.closest('[role="menuitem"]');
      if (!item || !this.popover.contains(item)) return;

      this._setOpen(false);
      const action = item.dataset.action;
      if (!action) return;

      if (action === 'open-shortcuts') {
        const m = document.getElementById('shortcuts-modal');
        if (m) m.classList.remove('hidden');
      } else if (action === 'open-command-palette') {
        openCommandPalette();
      }
    };

    this.trigger.addEventListener('click', this.toggle);
    document.addEventListener('click', this.outside, true);
    document.addEventListener('keydown', this.escape);
    this.popover.addEventListener('click', this.handleAction);
  },
  destroyed() {
    document.removeEventListener('click', this.outside, true);
    document.removeEventListener('keydown', this.escape);
  },
  _setOpen(open) {
    if (open) {
      this.popover.classList.remove('hidden');
      this.trigger.setAttribute('aria-expanded', 'true');
    } else {
      this.popover.classList.add('hidden');
      this.trigger.setAttribute('aria-expanded', 'false');
    }
  }
};

// Color swatch picker — clicking a preset fills the hex input + preview.
// Typing in the hex input live-updates the preview and the active swatch.
const ColorSwatchPicker = {
  mounted() {
    this.input = this.el.querySelector('[data-hex-input]');
    this.preview = this.el.querySelector('[data-color-preview]');
    if (!this.input) return;

    this.swatches = Array.from(this.el.querySelectorAll('[data-swatch]'));

    this.onSwatch = (e) => {
      const hex = e.currentTarget.dataset.hex;
      this.input.value = hex;
      this.input.dispatchEvent(new Event('input', {bubbles: true}));
      this._refresh();
    };

    this.onInput = () => this._refresh();

    this.swatches.forEach((s) => s.addEventListener('click', this.onSwatch));
    this.input.addEventListener('input', this.onInput);
    this._refresh();
  },
  _refresh() {
    const v = (this.input.value || '').toLowerCase().trim();
    if (this.preview && /^#[0-9a-f]{6}$/.test(v)) this.preview.style.backgroundColor = v;
    this.swatches.forEach((s) => {
      const active = s.dataset.hex.toLowerCase() === v;
      s.style.borderColor = active ? 'white' : 'rgba(255,255,255,0.15)';
    });
  }
};

// Adapter-specific config fields should follow the actual selected adapter,
// even before LiveView has re-rendered the form.
const AdapterConfigFields = {
  mounted() {
    this.sync = this.sync.bind(this);
    this.rememberAdapter = this.rememberAdapter.bind(this);
    this.rememberPanelField = this.rememberPanelField.bind(this);
    this.adapterSelect = null;
    this.profileSelect = null;
    this.pendingAdapter = null;
    this.pendingPanelFields = new Map();
    this.rememberProfile = this.rememberProfile.bind(this);
    this.clearPendingRuntimePreset = this.clearPendingRuntimePreset.bind(this);
    this.el.addEventListener('change', this.rememberPanelField);
    this.el.addEventListener('input', this.rememberPanelField);
    this.el.addEventListener('click', this.clearPendingRuntimePreset);
    this._bindSelect();
    this._bindProfileSelect();
    this.sync();
  },
  updated() {
    this._bindSelect();
    this._bindProfileSelect();
    this._restorePendingAdapter();
    this._restorePendingPanelFields();
    this.sync();
  },
  destroyed() {
    this._unbindSelect();
    this._unbindProfileSelect();
    this.el.removeEventListener('change', this.rememberPanelField);
    this.el.removeEventListener('input', this.rememberPanelField);
    this.el.removeEventListener('click', this.clearPendingRuntimePreset);
  },
  _bindSelect() {
    const nextSelect = this.el.querySelector('select[name="agent[adapter]"]');
    if (nextSelect === this.adapterSelect) return;

    this._unbindSelect();
    this.adapterSelect = nextSelect;

    if (this.adapterSelect) {
      this.adapterSelect.addEventListener('change', this.rememberAdapter);
      this.adapterSelect.addEventListener('input', this.rememberAdapter);
    }
  },
  _unbindSelect() {
    if (!this.adapterSelect || !this.rememberAdapter) return;

    this.adapterSelect.removeEventListener('change', this.rememberAdapter);
    this.adapterSelect.removeEventListener('input', this.rememberAdapter);
  },
  _bindProfileSelect() {
    const nextSelect = this.el.querySelector('select[name="agent[runtime_profile_id]"]');
    if (nextSelect === this.profileSelect) return;

    this._unbindProfileSelect();
    this.profileSelect = nextSelect;

    if (this.profileSelect) {
      this.profileSelect.addEventListener('change', this.rememberProfile);
      this.profileSelect.addEventListener('input', this.rememberProfile);
    }
  },
  _unbindProfileSelect() {
    if (!this.profileSelect || !this.rememberProfile) return;

    this.profileSelect.removeEventListener('change', this.rememberProfile);
    this.profileSelect.removeEventListener('input', this.rememberProfile);
  },
  _restorePendingAdapter() {
    if (!this.adapterSelect || !this.pendingAdapter) return;

    const hasOption = Array.from(this.adapterSelect.options).some(
      (option) => option.value === this.pendingAdapter
    );

    if (hasOption && this.adapterSelect.value !== this.pendingAdapter) {
      this.adapterSelect.value = this.pendingAdapter;
    }
  },
  rememberAdapter() {
    this.pendingAdapter = this.adapterSelect?.value || null;
    this.sync();
  },
  rememberProfile(event) {
    event?.stopPropagation?.();

    const option = this.profileSelect?.selectedOptions?.[0];
    const adapter = option?.dataset?.adapter;

    if (this.profileSelect) {
      this.pushEvent('select_runtime_profile', {
        profile_id: this.profileSelect.value || 'custom'
      });
    }

    if (!adapter) {
      this.sync();
      return;
    }

    this.pendingAdapter = adapter;

    if (this.adapterSelect && this.adapterSelect.value !== adapter) {
      this.adapterSelect.value = adapter;
    }

    this.sync();
  },
  clearPendingRuntimePreset(event) {
    if (!event.target?.closest?.('[data-runtime-preset]')) return;

    this.pendingAdapter = null;
    this.pendingPanelFields.clear();
  },
  rememberPanelField(event) {
    const target = event.target;
    if (!target || !target.name) return;

    const panel = target.closest('[data-adapter-panel]');
    if (!panel || panel.hidden || panel.classList.contains('hidden')) return;

    const adapter = panel.dataset.adapterPanel;
    if (!adapter) return;

    this.pendingPanelFields.set(`${adapter}:${target.name}`, target.value);
    this.sync();
  },
  _restorePendingPanelFields() {
    const adapter = this.pendingAdapter || this.adapterSelect?.value || 'claude_code';
    const panel = this.el.querySelector(`[data-adapter-panel="${adapter}"]`);
    if (!panel) return;

    panel.querySelectorAll('input[name], select[name], textarea[name]').forEach((control) => {
      const key = `${adapter}:${control.name}`;
      if (!this.pendingPanelFields.has(key)) return;

      const value = this.pendingPanelFields.get(key);
      if (control.tagName === 'SELECT') {
        const hasOption = Array.from(control.options).some((option) => option.value === value);
        if (hasOption) control.value = value;
        return;
      }

      control.value = value;
    });
  },
  _syncProviderModelSelect(panel) {
    const providerSelect = panel.querySelector('select[name="agent[provider]"]');
    const modelSelect = panel.querySelector('select[name="agent[model]"]');
    if (!providerSelect || !modelSelect) return;

    const provider = providerSelect.value || '';
    const options = Array.from(modelSelect.options);
    const scopedOptions = options.filter((option) => option.dataset.provider !== undefined);
    if (scopedOptions.length === 0) return;

    let firstVisible = null;
    let currentStillVisible = false;

    scopedOptions.forEach((option) => {
      const visible = option.dataset.provider === provider;
      option.hidden = !visible;
      option.disabled = !visible;

      if (visible) {
        firstVisible = firstVisible || option;
        if (option.value === modelSelect.value) currentStillVisible = true;
      }
    });

    if (!currentStillVisible && firstVisible) {
      modelSelect.value = firstVisible.value;
      this.pendingPanelFields.set(
        `${panel.dataset.adapterPanel}:${modelSelect.name}`,
        firstVisible.value
      );
    }
  },
  sync() {
    const adapter = this.pendingAdapter || this.adapterSelect?.value || 'claude_code';

    this.el.querySelectorAll('[data-adapter-panel]').forEach((panel) => {
      const visible = panel.dataset.adapterPanel === adapter;
      panel.hidden = !visible;
      panel.classList.toggle('hidden', !visible);
      if (visible) this._syncProviderModelSelect(panel);
      panel.querySelectorAll('input, select, textarea, button').forEach((control) => {
        control.disabled = !visible;
      });
    });
  }
};

// Sidebar primary "New issue" button — open the quick-create modal.
document.addEventListener('click', (e) => {
  const trig = e.target.closest('[data-quick-create-trigger]');
  if (trig && typeof window.openQuickCreate === 'function') {
    e.preventDefault();
    window.openQuickCreate();
  }
});

// The dashboard prompt bar has a standalone command-palette button outside
// the user-menu hook, so it needs the same delegated behavior here.
document.addEventListener('click', (e) => {
  const trig = e.target.closest('[data-action="open-command-palette"]');
  if (!trig || trig.getAttribute('role') === 'menuitem') return;

  e.preventDefault();
  openCommandPalette();
});

window.addEventListener('phx:issue:replace_url', (e) => {
  const cleanUrl = e.detail?.url;
  if (!cleanUrl) return;

  const target = new URL(cleanUrl, window.location.origin);
  if (window.location.href === target.href) return;

  window.history.replaceState(window.history.state, '', cleanUrl);
});

// Theme switch — the Appearance picker / user menu push `set-theme` after
// persisting the choice to the DB. Flip <html data-theme> live (no reload) and
// mirror it into the `theme` cookie so the next full load server-renders it
// (the FetchTheme plug reads this cookie), keeping first paint flash-free.
window.addEventListener('phx:set-theme', (e) => {
  const theme = e.detail?.theme;
  if (!theme) return;
  document.documentElement.setAttribute('data-theme', theme);
  document.cookie = `theme=${theme}; path=/; max-age=${60 * 60 * 24 * 365}; SameSite=Lax`;
});

// Nav chrome (desktop nav_rail + mobile bottom nav) lives in the root layout
// outside LiveView inner_content, so assign-only badge updates never patch the
// DOM. UserAuth pushes `nav_badges` after OwnerAttention/Inbox/approval
// refreshes; mirror counts into always-present [data-nav-badge] nodes.
window.addEventListener('phx:nav_badges', (e) => {
  const inbox = Number(e.detail?.inbox ?? 0);
  const approval = Number(e.detail?.approval ?? 0);
  updateNavBadgeNodes('inbox', inbox);
  updateNavBadgeNodes('approvals', approval);
});

function updateNavBadgeNodes(key, rawCount) {
  const count = Math.min(99, Math.max(0, Number.isFinite(rawCount) ? rawCount : 0));
  const visible = count > 0;

  document.querySelectorAll(`[data-nav-badge="${key}"]`).forEach((el) => {
    el.dataset.count = String(count);
    el.textContent = visible ? String(count) : '';
    el.classList.toggle('hidden', !visible);
    el.setAttribute('aria-hidden', visible ? 'false' : 'true');

    if (visible) {
      const mobile = Boolean(el.closest('#mobile-nav'));
      el.setAttribute(
        'data-testid',
        mobile ? `mobile-nav-badge-${key}` : `nav-badge-${key}`
      );
    } else {
      el.removeAttribute('data-testid');
    }
  });
}

// ---------------------------------------------------------------------------
// SelectMenu — styled, theme-matched replacement for native <select>.
//
// Document-delegated (NOT a phx-hook) so the same controller drives selects
// inside LiveViews and in the plain-JS root layout (the quick-create modal).
// Markup comes from CymphoWeb.Components.select_menu/1: a visually-hidden real
// <select data-select-native> (the value vehicle — posts with the form, is
// LiveViewTest/keyboard/screen-reader drivable), a <button data-select-trigger>
// showing the current label, and a <div data-select-popover> listbox of
// <li data-select-option>. Picking an option mirrors the value onto the native
// <select> and dispatches input/change so LiveView `phx-change` forms react
// exactly as they would to a real <select>; the server stays the source of
// truth via the bound `value`.
// ---------------------------------------------------------------------------
let openSelectEl = null;
let selectReposition = null;

// Shared: position `pop` as `position: fixed` anchored to `trigger` so it
// escapes any `overflow: hidden` ancestor (modals, cards, table cells) — e.g.
// the quick-create modal clips its rounded corners, which would otherwise hide
// the popover. Flips upward when there isn't room below. With `matchWidth` the
// popover takes the trigger's width (selects); otherwise it keeps its own width
// (date/time pickers). An optional `listEl` is height-capped to the space.
function positionPopover(trigger, pop, {matchWidth = false, listEl = null, flipThreshold = 200} = {}) {
  if (!trigger || !pop) return;
  const r = trigger.getBoundingClientRect();
  const gap = 4;
  const margin = 8;
  const below = window.innerHeight - r.bottom - margin;
  const above = r.top - margin;
  const openUp = below < flipThreshold && above > below;
  pop.style.position = 'fixed';
  pop.style.left = `${Math.round(r.left)}px`;
  if (matchWidth) {
    pop.style.width = `${Math.round(r.width)}px`;
    pop.style.minWidth = `${Math.round(r.width)}px`;
  }
  if (openUp) {
    pop.style.top = 'auto';
    pop.style.bottom = `${Math.round(window.innerHeight - r.top + gap)}px`;
  } else {
    pop.style.bottom = 'auto';
    pop.style.top = `${Math.round(r.bottom + gap)}px`;
  }
  if (listEl) listEl.style.maxHeight = `${Math.round(Math.max(120, (openUp ? above : below) - gap))}px`;
}

function positionSelectPopover(menu) {
  const trigger = menu.querySelector('[data-select-trigger]');
  const pop = menu.querySelector('[data-select-popover]');
  const list = menu.querySelector('[data-select-list]');
  positionPopover(trigger, pop, {matchWidth: true, listEl: list});
}

function closeSelectMenu(menu) {
  if (!menu) return;
  menu.querySelector('[data-select-popover]')?.classList.add('hidden');
  menu.querySelector('[data-select-trigger]')?.setAttribute('aria-expanded', 'false');
  menu.querySelectorAll('[data-select-active]').forEach((el) => el.removeAttribute('data-select-active'));
  if (openSelectEl === menu) openSelectEl = null;
  if (selectReposition) {
    window.removeEventListener('scroll', selectReposition, true);
    window.removeEventListener('resize', selectReposition);
    selectReposition = null;
  }
}

// A LiveView navigation/patch can remove an open select's DOM without an
// outside click; release its scroll/resize listeners on page-loading-stop.
window.addEventListener('phx:page-loading-stop', () => {
  if (openSelectEl && !openSelectEl.isConnected) closeSelectMenu(openSelectEl);
});

function openSelectMenu(menu) {
  if (!menu || menu.dataset.disabled === 'true') return;
  if (openSelectEl && openSelectEl !== menu) closeSelectMenu(openSelectEl);
  const pop = menu.querySelector('[data-select-popover]');
  if (!pop) return;
  pop.classList.remove('hidden');
  menu.querySelector('[data-select-trigger]')?.setAttribute('aria-expanded', 'true');
  openSelectEl = menu;
  positionSelectPopover(menu);
  // Keep the popover glued to its trigger while the page scrolls/resizes; if a
  // LiveView patch removed the menu's DOM, close it so the listeners don't leak.
  selectReposition = () => {
    if (!menu.isConnected) return closeSelectMenu(menu);
    positionSelectPopover(menu);
  };
  window.addEventListener('scroll', selectReposition, true);
  window.addEventListener('resize', selectReposition);
  // Highlight the selected option (or the first) for keyboard nav.
  const active = pop.querySelector('[data-select-selected="true"]') || pop.querySelector('[data-select-option]');
  if (active) {
    active.setAttribute('data-select-active', 'true');
    active.scrollIntoView({block: 'nearest'});
  }
}

function selectMenuOption(menu, option) {
  const native = menu.querySelector('[data-select-native]');
  const display = menu.querySelector('[data-select-display]');
  const value = option.dataset.selectOptionValue ?? '';
  const label = option.dataset.selectOptionLabel ?? '';

  if (native) {
    const changed = native.value !== value;
    native.value = value;
    if (changed) {
      // Bubble to the form so LiveView `phx-change` reacts as it would to a
      // real <select> pick — the native element is the source of truth.
      native.dispatchEvent(new Event('input', {bubbles: true}));
      native.dispatchEvent(new Event('change', {bubbles: true}));
    }
  }
  if (display) {
    display.textContent = label;
    display.classList.remove('text-ink-tertiary');
  }
  menu.querySelectorAll('[data-select-option]').forEach((opt) => {
    const isSel = opt === option;
    opt.setAttribute('data-select-selected', String(isSel));
    opt.setAttribute('aria-selected', String(isSel));
    opt.querySelector('[data-select-check]')?.classList.toggle('invisible', !isSel);
  });
  closeSelectMenu(menu);
  menu.querySelector('[data-select-trigger]')?.focus();
}

function moveSelectActive(menu, dir) {
  const opts = Array.from(menu.querySelectorAll('[data-select-option]'));
  if (!opts.length) return;
  let idx = opts.findIndex((o) => o.getAttribute('data-select-active') === 'true');
  idx =
    dir === 'home' ? 0
    : dir === 'end' ? opts.length - 1
    : idx < 0 ? (dir === 1 ? 0 : opts.length - 1)
    : Math.min(Math.max(idx + dir, 0), opts.length - 1);
  opts.forEach((o) => o.removeAttribute('data-select-active'));
  opts[idx].setAttribute('data-select-active', 'true');
  opts[idx].scrollIntoView({block: 'nearest'});
}

// One delegated click handler: toggle a trigger, pick an option, or close on
// any outside click. Survives LiveView DOM patches (no per-element listeners).
document.addEventListener('click', (e) => {
  const trigger = e.target.closest('[data-select-trigger]');
  if (trigger) {
    const menu = trigger.closest('[data-select-menu]');
    e.preventDefault();
    if (openSelectEl === menu) {
      closeSelectMenu(menu);
    } else {
      openSelectMenu(menu);
      trigger.focus(); // Safari doesn't focus <button> on click; needed for keys.
    }
    return;
  }
  const option = e.target.closest('[data-select-option]');
  if (option) {
    e.preventDefault();
    selectMenuOption(option.closest('[data-select-menu]'), option);
    return;
  }
  if (openSelectEl && !openSelectEl.contains(e.target)) closeSelectMenu(openSelectEl);
});

// Keyboard: open from a focused trigger, then arrows / enter / esc / home / end
// / type-ahead while open.
document.addEventListener('keydown', (e) => {
  const trigger = e.target.closest?.('[data-select-trigger]');
  if (trigger && openSelectEl !== trigger.closest('[data-select-menu]')) {
    if (e.key === 'ArrowDown' || e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      openSelectMenu(trigger.closest('[data-select-menu]'));
    }
    return;
  }
  const menu = openSelectEl;
  if (!menu) return;
  switch (e.key) {
    case 'Escape':
      e.preventDefault();
      closeSelectMenu(menu);
      menu.querySelector('[data-select-trigger]')?.focus();
      break;
    case 'ArrowDown': e.preventDefault(); moveSelectActive(menu, 1); break;
    case 'ArrowUp': e.preventDefault(); moveSelectActive(menu, -1); break;
    case 'Home': e.preventDefault(); moveSelectActive(menu, 'home'); break;
    case 'End': e.preventDefault(); moveSelectActive(menu, 'end'); break;
    case 'Tab': closeSelectMenu(menu); break;
    case 'Enter':
    case ' ': {
      e.preventDefault();
      const active = menu.querySelector('[data-select-option][data-select-active="true"]');
      if (active) selectMenuOption(menu, active);
      break;
    }
    default:
      // Type-ahead: jump to the next option whose label starts with the key.
      if (e.key.length === 1 && /\S/.test(e.key)) {
        const opts = Array.from(menu.querySelectorAll('[data-select-option]'));
        const ch = e.key.toLowerCase();
        const match = opts.find((o) => (o.dataset.selectOptionLabel || '').toLowerCase().startsWith(ch));
        if (match) {
          opts.forEach((o) => o.removeAttribute('data-select-active'));
          match.setAttribute('data-select-active', 'true');
          match.scrollIntoView({block: 'nearest'});
        }
      }
  }
});

// Backward-compatible cleanup hook for older issue-page diffs. The current
// issue page uses a pushed event, but keeping this hook registered prevents
// stale browser DOM from logging unknown-hook errors during hot reloads.
const IssueGateCleanup = {
  mounted() {
    const cleanUrl = this.el.dataset.cleanUrl;
    if (!cleanUrl) return;

    const target = new URL(cleanUrl, window.location.origin);
    if (window.location.href !== target.href) {
      window.history.replaceState(window.history.state, '', cleanUrl);
    }
  }
};

// ---------------------------------------------------------------------------
// DatePicker — theme-matched calendar / time / datetime picker (phx-hook).
//
// Builds the popover UI into the shells rendered by
// CymphoWeb.Components.DatePicker. The hook OWNS the popover DOM (root is
// phx-update="ignore"); the visually-hidden real <input data-picker-native> is
// the source of truth — on pick we set its value and dispatch bubbling
// input/change so phx-change forms react like a native control. Modes: "date"
// (calendar), "time" (HH:MM columns, 24h), "datetime" (calendar + time row).
// Values are naive wall-clock strings; parse with parseYMD, NEVER new Date(str)
// (which is UTC and shifts a day in negative-offset zones).
// ---------------------------------------------------------------------------
const PICKER_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const PICKER_DOW = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"];

function pickerParseYMD(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s || "");
  return m ? new Date(+m[1], +m[2] - 1, +m[3]) : null; // local midnight, no TZ shift
}
function pickerFmtYMD(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
function pickerPad2(n) {
  return String(n).padStart(2, "0");
}

const DatePicker = {
  mounted() {
    this.mode = this.el.dataset.pickerMode || "date";
    this.minuteStep = Math.max(1, parseInt(this.el.dataset.minuteStep || "5", 10));
    this.native = this.el.querySelector("[data-picker-native]");
    this.trigger = this.el.querySelector("[data-picker-trigger]");
    this.pop = this.el.querySelector("[data-picker-popover]");
    this.calEl = this.el.querySelector("[data-picker-calendar]");
    this.timeEl = this.el.querySelector("[data-picker-time]");
    this._syncFromNative();

    this._onTriggerClick = (e) => { e.preventDefault(); this._toggle(); };
    this._onTriggerKey = (e) => this._onTriggerKeydown(e);
    this._onPopKey = (e) => this._onPopoverKeydown(e);
    this._docClick = (e) => { if (!this.el.contains(e.target)) this._close(); };
    this.trigger.addEventListener("click", this._onTriggerClick);
    this.trigger.addEventListener("keydown", this._onTriggerKey);
    this.pop.addEventListener("keydown", this._onPopKey);
    document.addEventListener("click", this._docClick);

    // Escape hatch for the root being phx-update="ignore": a server can clear
    // the picker after mount (e.g. audit-trail "Clear filters") by pushing
    // "datepicker:reset". Without this the native value would stay stale.
    this._resetRef = this.handleEvent("datepicker:reset", () => this._reset());

    this._renderLabel();
  },
  updated() {
    // Root is phx-update="ignore", but re-read the native value as the source of
    // truth in case a server patch reached the attribute.
    this._syncFromNative();
    this._renderLabel();
    if (!this.pop.classList.contains("hidden")) this._renderBody();
  },
  destroyed() {
    document.removeEventListener("click", this._docClick);
    if (this._resetRef) this.removeHandleEvent(this._resetRef);
    this._teardownRepos();
  },

  _reset() {
    this.native.value = "";
    this._syncFromNative();
    if (!this.pop.classList.contains("hidden")) this._renderBody();
    this._renderLabel();
  },

  _syncFromNative() {
    const v = this.native.value || "";
    if (this.mode === "date") { this.date = v || null; this.time = null; }
    else if (this.mode === "time") { this.date = null; this.time = v || null; }
    else {
      const [d, t] = v.split("T");
      this.date = d || null;
      this.time = t ? t.slice(0, 5) : null;
    }
    const base = pickerParseYMD(this.date) || new Date();
    this.viewYear = base.getFullYear();
    this.viewMonth = base.getMonth();
  },

  _toggle() {
    this.pop.classList.contains("hidden") ? this._open() : this._close();
  },
  _open() {
    if (this.el.dataset.disabled === "true") return;
    if (this.mode === "datetime" && !this.date) this.date = pickerFmtYMD(new Date());
    this._renderBody();
    this.pop.classList.remove("hidden");
    this.trigger.setAttribute("aria-expanded", "true");
    const flip = this.mode === "time" ? 200 : 320;
    const reposition = () => positionPopover(this.trigger, this.pop, {flipThreshold: flip});
    reposition();
    this._repos = reposition;
    window.addEventListener("scroll", this._repos, true);
    window.addEventListener("resize", this._repos);
    requestAnimationFrame(() => this._focusInitial());
  },
  _close() {
    this.pop.classList.add("hidden");
    this.trigger.setAttribute("aria-expanded", "false");
    this._teardownRepos();
  },
  _teardownRepos() {
    if (this._repos) {
      window.removeEventListener("scroll", this._repos, true);
      window.removeEventListener("resize", this._repos);
      this._repos = null;
    }
  },
  _renderBody() {
    if (this.mode !== "time") this._renderCalendar();
    if (this.mode !== "date") this._renderTime();
  },

  // ── Calendar ──────────────────────────────────────────────────────────────
  _renderCalendar() {
    const sel = pickerParseYMD(this.date);
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const minD = pickerParseYMD(this.el.dataset.min);
    const maxD = pickerParseYMD(this.el.dataset.max);
    const y = this.viewYear, m = this.viewMonth;
    const first = new Date(y, m, 1);
    const lead = (first.getDay() + 6) % 7; // Monday = 0
    const start = new Date(y, m, 1 - lead);

    let html =
      `<div class="flex items-center justify-between px-1 pb-2">` +
      `<button type="button" data-picker-prev aria-label="Previous month" class="h-7 w-7 flex items-center justify-center rounded-sm text-ink-tertiary hover:bg-surface-3 hover:text-ink"><span class="hero-chevron-left-mini w-4 h-4"></span></button>` +
      `<span class="text-caption font-590 text-ink">${PICKER_MONTHS[m]} ${y}</span>` +
      `<button type="button" data-picker-next aria-label="Next month" class="h-7 w-7 flex items-center justify-center rounded-sm text-ink-tertiary hover:bg-surface-3 hover:text-ink"><span class="hero-chevron-right-mini w-4 h-4"></span></button>` +
      `</div>` +
      `<div class="grid grid-cols-7 gap-0.5 mb-1">` +
      PICKER_DOW.map((d) => `<div class="h-6 flex items-center justify-center text-[11px] text-ink-tertiary">${d}</div>`).join("") +
      `</div><div class="grid grid-cols-7 gap-0.5">`;

    for (let i = 0; i < 42; i++) {
      const d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
      const inMonth = d.getMonth() === m;
      const isToday = d.getTime() === today.getTime();
      const isSel = sel && d.getTime() === sel.getTime();
      const disabled = (minD && d < minD) || (maxD && d > maxD);
      let cls = "h-8 w-full flex items-center justify-center rounded-sm text-caption tabular-nums select-none ";
      if (disabled) cls += "text-ink-tertiary opacity-40 cursor-not-allowed pointer-events-none";
      else if (isSel) cls += "bg-primary text-on-primary cursor-pointer";
      else if (isToday) cls += (inMonth ? "text-ink " : "text-ink-tertiary ") + "ring-1 ring-primary cursor-pointer hover:bg-surface-3";
      else cls += (inMonth ? "text-ink " : "text-ink-tertiary ") + "cursor-pointer hover:bg-surface-3";
      const tab = isSel || (!sel && isToday) ? "0" : "-1";
      html += `<button type="button" data-picker-day data-date="${pickerFmtYMD(d)}" role="gridcell" tabindex="${tab}"${disabled ? " disabled" : ""} class="${cls}">${d.getDate()}</button>`;
    }
    html += `</div>`;
    this.calEl.innerHTML = html;

    this.calEl.querySelector("[data-picker-prev]").addEventListener("click", (e) => { e.preventDefault(); this._shiftMonth(-1); });
    this.calEl.querySelector("[data-picker-next]").addEventListener("click", (e) => { e.preventDefault(); this._shiftMonth(1); });
    this.calEl.querySelectorAll("[data-picker-day]").forEach((btn) =>
      btn.addEventListener("click", (e) => { e.preventDefault(); this._pickDay(btn.dataset.date); })
    );
  },
  _shiftMonth(delta) {
    this.viewMonth += delta;
    if (this.viewMonth < 0) { this.viewMonth = 11; this.viewYear--; }
    else if (this.viewMonth > 11) { this.viewMonth = 0; this.viewYear++; }
    this._renderCalendar();
  },
  _pickDay(ymd) {
    this.date = ymd;
    const d = pickerParseYMD(ymd);
    this.viewYear = d.getFullYear();
    this.viewMonth = d.getMonth();
    this._commit();
    if (this.mode === "date") { this._close(); this.trigger.focus(); }
    else { this._renderCalendar(); this._focusDate(d); }
  },

  // ── Time ──────────────────────────────────────────────────────────────────
  _renderTime() {
    const [selH, selM] = (this.time || "").split(":");
    const hours = Array.from({length: 24}, (_, h) => pickerPad2(h));
    const mins = [];
    for (let mm = 0; mm < 60; mm += this.minuteStep) mins.push(pickerPad2(mm));
    if (selM && !mins.includes(selM)) { mins.push(selM); mins.sort(); } // round-trip off-step

    const col = (items, sel, kind) =>
      `<div class="flex-1 max-h-[11rem] overflow-y-auto" data-picker-col="${kind}">` +
      items
        .map((v) => {
          const on = v === sel;
          const cls = "h-8 w-full flex items-center justify-center rounded-sm text-caption tabular-nums cursor-pointer " + (on ? "bg-primary text-on-primary" : "text-ink hover:bg-surface-3");
          return `<button type="button" data-picker-${kind} data-val="${v}" tabindex="${on ? "0" : "-1"}" class="${cls}">${v}</button>`;
        })
        .join("") +
      `</div>`;

    this.timeEl.innerHTML =
      `<div class="flex gap-2">` +
      `<div class="flex-1"><div class="text-[11px] text-ink-tertiary text-center pb-1">Hour</div>${col(hours, selH, "hour")}</div>` +
      `<div class="flex-1"><div class="text-[11px] text-ink-tertiary text-center pb-1">Min</div>${col(mins, selM, "min")}</div>` +
      `</div>`;

    this.timeEl.querySelectorAll("[data-picker-hour]").forEach((b) => b.addEventListener("click", (e) => { e.preventDefault(); this._pickTime(b.dataset.val, null); }));
    this.timeEl.querySelectorAll("[data-picker-min]").forEach((b) => b.addEventListener("click", (e) => { e.preventDefault(); this._pickTime(null, b.dataset.val); }));
    this.timeEl.querySelectorAll('[tabindex="0"]').forEach((b) => b.scrollIntoView({block: "center"}));
  },
  _pickTime(h, mm) {
    const [curH, curM] = (this.time || "00:00").split(":");
    this.time = `${h != null ? h : curH || "00"}:${mm != null ? mm : curM || "00"}`;
    this._commit();
    this._highlightTime();
  },
  _highlightTime() {
    const [selH, selM] = (this.time || "").split(":");
    this.timeEl.querySelectorAll("[data-picker-hour]").forEach((b) => this._setTimeOn(b, b.dataset.val === selH));
    this.timeEl.querySelectorAll("[data-picker-min]").forEach((b) => this._setTimeOn(b, b.dataset.val === selM));
  },
  _setTimeOn(btn, on) {
    btn.classList.toggle("bg-primary", on);
    btn.classList.toggle("text-on-primary", on);
    btn.classList.toggle("text-ink", !on);
    btn.classList.toggle("hover:bg-surface-3", !on);
  },

  // ── Commit / label ─────────────────────────────────────────────────────────
  _commit() {
    let v = "";
    if (this.mode === "date") v = this.date || "";
    else if (this.mode === "time") v = this.time || "";
    else if (this.date) v = `${this.date}T${this.time || "00:00"}`;
    if (this.native.value !== v) {
      this.native.value = v;
      this.native.dispatchEvent(new Event("input", {bubbles: true}));
      this.native.dispatchEvent(new Event("change", {bubbles: true}));
    }
    this._renderLabel();
  },
  _renderLabel() {
    const disp = this.el.querySelector("[data-picker-display]");
    const v = this.native.value;
    if (!v) {
      disp.textContent = this.el.dataset.placeholder || "…";
      disp.classList.add("text-ink-tertiary");
      return;
    }
    let text;
    if (this.mode === "date") {
      const d = pickerParseYMD(v);
      text = d ? `${PICKER_MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}` : v;
    } else if (this.mode === "time") {
      text = v;
    } else {
      const [dp, tp] = v.split("T");
      const d = pickerParseYMD(dp);
      text = d ? `${PICKER_MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()} · ${tp || "00:00"}` : v;
    }
    disp.textContent = text;
    disp.classList.remove("text-ink-tertiary");
  },

  // ── Keyboard ────────────────────────────────────────────────────────────────
  _onTriggerKeydown(e) {
    if (this.pop.classList.contains("hidden")) {
      if (e.key === "ArrowDown" || e.key === "Enter" || e.key === " ") { e.preventDefault(); this._open(); }
    } else if (e.key === "Escape") {
      e.preventDefault();
      this._close();
    }
  },
  _onPopoverKeydown(e) {
    if (e.key === "Escape") { e.preventDefault(); this._close(); this.trigger.focus(); return; }
    if (e.key === "Tab") { this._close(); return; }
    const timeBtn = e.target.closest && e.target.closest("[data-picker-hour], [data-picker-min]");
    if (timeBtn) return this._onTimeKeydown(e, timeBtn);
    const day = e.target.closest && e.target.closest("[data-picker-day]");
    if (!day) return;
    let delta = 0;
    if (e.key === "ArrowLeft") delta = -1;
    else if (e.key === "ArrowRight") delta = 1;
    else if (e.key === "ArrowUp") delta = -7;
    else if (e.key === "ArrowDown") delta = 7;
    else if (e.key === "PageUp") { e.preventDefault(); this._shiftMonth(-1); this._focusDayFallback(); return; }
    else if (e.key === "PageDown") { e.preventDefault(); this._shiftMonth(1); this._focusDayFallback(); return; }
    else if (e.key === "Enter" || e.key === " ") { e.preventDefault(); if (!day.disabled) this._pickDay(day.dataset.date); return; }
    else return;
    e.preventDefault();
    const base = pickerParseYMD(day.dataset.date);
    this._focusDate(new Date(base.getFullYear(), base.getMonth(), base.getDate() + delta));
  },
  _onTimeKeydown(e, btn) {
    const col = btn.closest("[data-picker-col]");
    const items = Array.from(col.querySelectorAll("button"));
    const idx = items.indexOf(btn);
    if (e.key === "ArrowDown") { e.preventDefault(); (items[idx + 1] || items[0]).focus(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); (items[idx - 1] || items[items.length - 1]).focus(); }
    else if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
      e.preventDefault();
      const other = this.timeEl.querySelector(col.dataset.pickerCol === "hour" ? "[data-picker-min]" : "[data-picker-hour]");
      if (other) (this.timeEl.querySelector(`[data-picker-${col.dataset.pickerCol === "hour" ? "min" : "hour"}][tabindex="0"]`) || other).focus();
    } else if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      if (col.dataset.pickerCol === "hour") this._pickTime(btn.dataset.val, null);
      else this._pickTime(null, btn.dataset.val);
      btn.focus();
    }
  },
  _focusDate(target) {
    if (target.getMonth() !== this.viewMonth || target.getFullYear() !== this.viewYear) {
      this.viewYear = target.getFullYear();
      this.viewMonth = target.getMonth();
      this._renderCalendar();
    }
    const cell = this.calEl.querySelector(`[data-picker-day][data-date="${pickerFmtYMD(target)}"]`);
    if (cell) {
      this.calEl.querySelectorAll("[data-picker-day]").forEach((b) => (b.tabIndex = -1));
      cell.tabIndex = 0;
      cell.focus();
    }
  },
  _focusDayFallback() {
    const cell = this.calEl.querySelector('[data-picker-day][tabindex="0"]') || this.calEl.querySelector("[data-picker-day]:not([disabled])");
    if (cell) cell.focus();
  },
  _focusInitial() {
    if (this.mode === "time") {
      const sel = this.timeEl.querySelector('[data-picker-hour][tabindex="0"]') || this.timeEl.querySelector("[data-picker-hour]");
      if (sel) sel.focus();
    } else {
      this._focusDayFallback();
    }
  }
};

const CopyToClipboard = {
  mounted() {
    this.handleClick = (event) => {
      const button = event.target.closest("[data-copy-text]");
      if (!button || !this.el.contains(button)) return;

      event.preventDefault();
      this._copy(button.dataset.copyText || "", button);
    };

    this.el.addEventListener("click", this.handleClick);
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick);
  },

  async _copy(text, button) {
    if (!text) return;

    try {
      await this._writeText(text);
      this._flash(button, button.dataset.copySuccessLabel || "Copied");
    } catch (_error) {
      this._flash(button, button.dataset.copyErrorLabel || "Copy failed");
    }
  },

  async _writeText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      try {
        await navigator.clipboard.writeText(text);
        return;
      } catch (_error) {
        // Fall back to selection-based copy below.
      }
    }

    if (!this._fallbackCopy(text)) {
      throw new Error("copy failed");
    }
  },

  _fallbackCopy(text) {
    let wroteClipboardData = false;
    const writeClipboardData = (event) => {
      if (!event.clipboardData) return;
      event.clipboardData.setData("text/plain", text);
      event.preventDefault();
      wroteClipboardData = true;
    };

    document.addEventListener("copy", writeClipboardData, true);
    try {
      if (document.execCommand("copy") && wroteClipboardData) {
        return true;
      }
    } finally {
      document.removeEventListener("copy", writeClipboardData, true);
    }

    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.top = "0";
    textarea.style.left = "0";
    textarea.style.opacity = "0";
    document.body.appendChild(textarea);

    try {
      textarea.focus();
      textarea.select();
      textarea.setSelectionRange(0, text.length);
      return document.execCommand("copy");
    } finally {
      textarea.remove();
    }
  },

  _flash(button, label) {
    const originalHtml = button.dataset.copyOriginalHtml || button.innerHTML;
    const originalLabel = button.dataset.copyLabel || button.textContent.trim();

    button.dataset.copyOriginalHtml = originalHtml;
    button.textContent = label;
    button.dataset.copied = "true";

    window.clearTimeout(button._copyResetTimer);
    button._copyResetTimer = window.setTimeout(() => {
      button.innerHTML = originalHtml;
      if (originalLabel) button.dataset.copyLabel = originalLabel;
      delete button.dataset.copied;
    }, 1200);
  }
};

// Company imports are content-addressed and uploaded sequentially in bounded
// parts. The hook deliberately uses the browser session + CSRF token rather
// than exposing a reusable API bearer token to page JavaScript.
const COMPANY_IMPORT_PART_BYTES = 4 * 1024 * 1024;
const COMPANY_IMPORT_MAX_BYTES = 50_000_000;

const SHA256_K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]);

function rotateRight(value, amount) {
  return (value >>> amount) | (value << (32 - amount));
}

class IncrementalSha256 {
  constructor() {
    this.state = new Uint32Array([
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]);
    this.buffer = new Uint8Array(64);
    this.bufferLength = 0;
    this.bytesHashed = 0;
    this.words = new Uint32Array(64);
  }

  update(input) {
    const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
    this.bytesHashed += bytes.length;
    let offset = 0;

    if (this.bufferLength > 0) {
      const take = Math.min(64 - this.bufferLength, bytes.length);
      this.buffer.set(bytes.subarray(0, take), this.bufferLength);
      this.bufferLength += take;
      offset += take;
      if (this.bufferLength === 64) {
        this._compress(this.buffer);
        this.bufferLength = 0;
      }
    }

    while (offset + 64 <= bytes.length) {
      this._compress(bytes.subarray(offset, offset + 64));
      offset += 64;
    }

    if (offset < bytes.length) {
      this.buffer.set(bytes.subarray(offset), 0);
      this.bufferLength = bytes.length - offset;
    }
    return this;
  }

  hexDigest() {
    const bitLength = this.bytesHashed * 8;
    const finalLength = this.bufferLength < 56 ? 64 : 128;
    const tail = new Uint8Array(finalLength);
    tail.set(this.buffer.subarray(0, this.bufferLength));
    tail[this.bufferLength] = 0x80;

    const view = new DataView(tail.buffer);
    view.setUint32(finalLength - 8, Math.floor(bitLength / 0x100000000), false);
    view.setUint32(finalLength - 4, bitLength >>> 0, false);
    for (let offset = 0; offset < finalLength; offset += 64) {
      this._compress(tail.subarray(offset, offset + 64));
    }

    return Array.from(this.state)
      .map((word) => word.toString(16).padStart(8, "0"))
      .join("");
  }

  _compress(block) {
    const words = this.words;
    const view = new DataView(block.buffer, block.byteOffset, block.byteLength);
    for (let index = 0; index < 16; index += 1) {
      words[index] = view.getUint32(index * 4, false);
    }
    for (let index = 16; index < 64; index += 1) {
      const x = words[index - 15];
      const y = words[index - 2];
      const sigma0 = rotateRight(x, 7) ^ rotateRight(x, 18) ^ (x >>> 3);
      const sigma1 = rotateRight(y, 17) ^ rotateRight(y, 19) ^ (y >>> 10);
      words[index] = (words[index - 16] + sigma0 + words[index - 7] + sigma1) >>> 0;
    }

    let [a, b, c, d, e, f, g, h] = this.state;
    for (let index = 0; index < 64; index += 1) {
      const sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
      const choice = (e & f) ^ (~e & g);
      const temp1 = (h + sum1 + choice + SHA256_K[index] + words[index]) >>> 0;
      const sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
      const majority = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (sum0 + majority) >>> 0;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }

    this.state[0] = (this.state[0] + a) >>> 0;
    this.state[1] = (this.state[1] + b) >>> 0;
    this.state[2] = (this.state[2] + c) >>> 0;
    this.state[3] = (this.state[3] + d) >>> 0;
    this.state[4] = (this.state[4] + e) >>> 0;
    this.state[5] = (this.state[5] + f) >>> 0;
    this.state[6] = (this.state[6] + g) >>> 0;
    this.state[7] = (this.state[7] + h) >>> 0;
  }
}

function bytesToHex(buffer) {
  return Array.from(new Uint8Array(buffer), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

const CompanyImportTransfer = {
  mounted() {
    this.transferId = this.el.dataset.transferId || null;
    this.cancelled = false;
    this.requestController = null;
    this.workflowGeneration = 0;

    this.onChange = (event) => {
      if (!event.target.matches("[data-transfer-file]")) return;
      const file = event.target.files && event.target.files[0];
      if (file) {
        // Browsers do not fire another change event when the same file remains
        // selected. Clear only the native control; the File object stays valid
        // for this workflow and the progress UI keeps the filename visible.
        event.target.value = "";
        this.start(file);
      }
    };
    this.onClick = (event) => {
      if (!event.target.closest("[data-transfer-cancel]")) return;
      event.preventDefault();
      this.cancel();
    };
    this.el.addEventListener("change", this.onChange);
    this.el.addEventListener("click", this.onClick);

    this.handleEvent("company-import:preview", ({transfer_id, slug_strategy}) => {
      this.transferId = transfer_id;
      this.preview(slug_strategy);
    });
    this.handleEvent("company-import:apply", ({transfer_id, slug_strategy}) => {
      this.transferId = transfer_id;
      this.apply(slug_strategy);
    });
    this.handleEvent("company-import:reset", ({transfer_id}) => {
      this.invalidateWorkflow();
      this.deleteTransfer(transfer_id);
      this.transferId = null;
      this.resetProgress();
    });
  },

  updated() {
    if (this.el.dataset.transferId) this.transferId = this.el.dataset.transferId;
  },

  destroyed() {
    this.invalidateWorkflow();
    this.el.removeEventListener("change", this.onChange);
    this.el.removeEventListener("click", this.onClick);
  },

  async start(file) {
    const workflow = this.beginWorkflow();

    if (file.size <= 0 || file.size > COMPANY_IMPORT_MAX_BYTES) {
      this.fail("Choose a non-empty JSON export no larger than 50 MB.");
      return;
    }
    if (!file.name.toLowerCase().endsWith(".json")) {
      this.fail("Choose a JSON export file.");
      return;
    }
    if (!window.crypto || !window.crypto.subtle) {
      this.fail("Secure file hashing is unavailable in this browser.");
      return;
    }

    this.showProgress(file.name, "Verifying file…", 0);

    try {
      const partCount = Math.ceil(file.size / COMPANY_IMPORT_PART_BYTES);
      const parts = [];
      const wholeHash = new IncrementalSha256();

      for (let position = 0; position < partCount; position += 1) {
        this.throwIfSuperseded(workflow);
        const start = position * COMPANY_IMPORT_PART_BYTES;
        const end = Math.min(start + COMPANY_IMPORT_PART_BYTES, file.size);
        const bytes = new Uint8Array(await file.slice(start, end).arrayBuffer());
        this.throwIfSuperseded(workflow);
        wholeHash.update(bytes);
        const partHash = await window.crypto.subtle.digest("SHA-256", bytes);
        this.throwIfSuperseded(workflow);
        parts.push({position, byte_size: bytes.byteLength, sha256: bytesToHex(partHash)});
        this.showProgress(file.name, `Verifying part ${position + 1} of ${partCount}…`,
          Math.round(((position + 1) / partCount) * 30));
      }

      const fileSha256 = wholeHash.hexDigest();
      const slugStrategy =
        this.el.querySelector("[data-transfer-strategy]:checked")?.value === "fail" ?
          "fail" : "suffix";
      const declaration = await this.request(this.basePath(), {
        method: "POST",
        json: {
          idempotency_key: `cympho_${fileSha256}_${slugStrategy}`,
          total_bytes: file.size,
          part_size_bytes: COMPANY_IMPORT_PART_BYTES,
          file_sha256: fileSha256,
          import_options: {slug_strategy: slugStrategy},
          parts
        }
      }, workflow);
      this.throwIfSuperseded(workflow);

      const transferId = declaration.transfer_id;
      this.transferId = transferId;
      this.pushEvent("transfer_declared", {
        transfer_id: transferId,
        slug_strategy: slugStrategy
      });
      if (declaration.already_completed === true) {
        this.showProgress(file.name, "This export was already imported.", 100);
        this.pushEvent("transfer_completed", {
          transfer_id: transferId,
          imported_company_id: declaration.imported_company_id,
          secrets_to_restore: declaration.secrets_to_restore,
          restore_receipt_available: declaration.restore_receipt_available
        });
        return;
      }
      const missing = Array.isArray(declaration.missing_parts) ? declaration.missing_parts : [];
      const missingSet = new Set(missing);
      let uploadedMissing = 0;

      for (let position = 0; position < partCount; position += 1) {
        if (!missingSet.has(position)) continue;
        this.throwIfSuperseded(workflow);
        const start = position * COMPANY_IMPORT_PART_BYTES;
        const end = Math.min(start + COMPANY_IMPORT_PART_BYTES, file.size);
        const bytes = new Uint8Array(await file.slice(start, end).arrayBuffer());
        this.throwIfSuperseded(workflow);
        await this.request(`${this.basePath()}/${transferId}/parts/${position}`, {
          method: "PUT",
          body: bytes,
          contentType: "application/octet-stream"
        }, workflow);
        uploadedMissing += 1;
        const uploaded = declaration.uploaded_parts + uploadedMissing;
        this.showProgress(file.name, `Uploaded ${uploaded} of ${partCount} parts…`,
          30 + Math.round((uploaded / partCount) * 60));
      }

      this.showProgress(file.name, "Building import preview…", 94);
      await this.previewTransfer(slugStrategy, file.name, transferId, workflow);
    } catch (error) {
      if (this.isWorkflowSuperseded(workflow) || (error && error.name === "AbortError")) return;
      this.fail(error instanceof Error ? error.message : "The transfer could not be completed.");
    }
  },

  async preview(slugStrategy, filename = "Company export") {
    if (!this.transferId) return;
    const transferId = this.transferId;
    const workflow = this.beginWorkflow();
    await this.previewTransfer(slugStrategy, filename, transferId, workflow);
  },

  async previewTransfer(slugStrategy, filename, transferId, workflow) {
    try {
      const response = await this.request(`${this.basePath()}/${transferId}/preview`, {
        method: "POST",
        json: {slug_strategy: slugStrategy}
      }, workflow);
      this.throwIfSuperseded(workflow);
      this.showProgress(filename, "Ready to review.", 100);
      this.pushEvent("transfer_previewed", {
        transfer_id: transferId,
        slug_strategy: slugStrategy,
        preview: response.data
      });
    } catch (error) {
      if (this.isWorkflowSuperseded(workflow) || (error && error.name === "AbortError")) return;
      const message = error instanceof Error ? error.message : "The preview could not be created.";
      this.showProgress(filename, message, 0);
      this.pushEvent("transfer_preview_failed", {error: message});
    }
  },

  async apply(slugStrategy) {
    if (!this.transferId) return;
    const transferId = this.transferId;
    const workflow = this.beginWorkflow();
    try {
      // Applying changes data, so do not automatically replay an ambiguous
      // network failure. The backend's claim prevents concurrent applies.
      const response = await this.request(`${this.basePath()}/${transferId}/apply`, {
        method: "POST",
        json: {slug_strategy: slugStrategy},
        attempts: 1
      }, workflow);
      this.throwIfSuperseded(workflow);
      this.pushEvent("transfer_applied", {transfer_id: transferId, result: response});
    } catch (error) {
      if (this.isWorkflowSuperseded(workflow) || (error && error.name === "AbortError")) return;
      this.pushEvent("transfer_apply_failed", {
        error: error instanceof Error ? error.message : "The import could not be completed."
      });
    }
  },

  async cancel() {
    this.invalidateWorkflow();
    this.transferId = null;
    this.resetProgress();
    this.pushEvent("transfer_cancelled", {});
  },

  async deleteTransfer(transferId) {
    if (!transferId) return;
    try {
      await fetch(`${this.basePath()}/${transferId}`, {
        method: "DELETE",
        credentials: "same-origin",
        headers: this.headers()
      });
    } catch (_error) {
      // The transfer sweeper handles abandoned ledgers if the browser is gone.
    }
  },

  async request(url, options, workflow) {
    const attempts = options.attempts || 4;
    let lastError;
    for (let attempt = 0; attempt < attempts; attempt += 1) {
      this.throwIfSuperseded(workflow);
      try {
        const headers = this.headers(options.contentType);
        const fetchOptions = {
          method: options.method,
          credentials: "same-origin",
          signal: workflow.controller.signal,
          headers
        };
        if (options.json !== undefined) {
          headers["content-type"] = "application/json";
          fetchOptions.body = JSON.stringify(options.json);
        } else if (options.body !== undefined) {
          fetchOptions.body = options.body;
        }

        const response = await fetch(url, fetchOptions);
        this.throwIfSuperseded(workflow);
        const payload = response.status === 204 ? {} : await this.responsePayload(response);
        this.throwIfSuperseded(workflow);
        if (response.ok) return payload;

        const message = payload.error || `Transfer request failed (${response.status}).`;
        const error = new Error(message);
        error.retryable = response.status === 408 || response.status === 425 ||
          response.status === 429 || response.status >= 500;
        throw error;
      } catch (error) {
        if (error && error.name === "AbortError") throw error;
        this.throwIfSuperseded(workflow);
        lastError = error;
        if ((error && error.retryable === false) || attempt === attempts - 1) throw error;
        await this.delay(300 * (2 ** attempt) + Math.floor(Math.random() * 150), workflow);
      }
    }
    throw lastError;
  },

  async responsePayload(response) {
    const type = response.headers.get("content-type") || "";
    if (type.includes("application/json")) return response.json();
    return {error: `Transfer request failed (${response.status}).`};
  },

  headers(contentType) {
    const headers = {accept: "application/json"};
    const token = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
    if (token) headers["x-csrf-token"] = token;
    if (contentType) headers["content-type"] = contentType;
    return headers;
  },

  basePath() {
    return this.el.dataset.basePath;
  },

  delay(milliseconds, workflow) {
    return new Promise((resolve, reject) => {
      const timer = window.setTimeout(resolve, milliseconds);
      workflow.controller.signal.addEventListener("abort", () => {
        window.clearTimeout(timer);
        reject(new DOMException("Aborted", "AbortError"));
      }, {once: true});
    });
  },

  beginWorkflow() {
    if (this.requestController) this.requestController.abort();
    this.cancelled = false;
    this.workflowGeneration = (this.workflowGeneration || 0) + 1;
    const controller = new AbortController();
    this.requestController = controller;
    return {generation: this.workflowGeneration, controller};
  },

  invalidateWorkflow() {
    this.cancelled = true;
    this.workflowGeneration = (this.workflowGeneration || 0) + 1;
    if (this.requestController) this.requestController.abort();
    this.requestController = null;
  },

  throwIfSuperseded(workflow) {
    if (this.isWorkflowSuperseded(workflow)) {
      throw new DOMException("Aborted", "AbortError");
    }
  },

  isWorkflowSuperseded(workflow) {
    return this.cancelled || !workflow || workflow.generation !== this.workflowGeneration ||
      workflow.controller.signal.aborted;
  },

  fail(message) {
    this.showProgress("Company export", message, 0);
    this.pushEvent("transfer_failed", {error: message});
  },

  showProgress(filename, status, percent) {
    const container = this.el.querySelector("[data-transfer-progress]");
    if (!container) return;
    const bounded = Math.max(0, Math.min(100, percent));
    container.classList.remove("hidden");
    const filenameElement = container.querySelector("[data-transfer-filename]");
    const percentElement = container.querySelector("[data-transfer-percent]");
    const statusElement = container.querySelector("[data-transfer-status]");
    const bar = container.querySelector("[data-transfer-progressbar]");
    const fill = container.querySelector("[data-transfer-progressfill]");
    if (filenameElement) filenameElement.textContent = filename;
    if (percentElement) percentElement.textContent = `${bounded}%`;
    if (statusElement) statusElement.textContent = status;
    if (bar) bar.setAttribute("aria-valuenow", String(bounded));
    if (fill) fill.style.transform = `scaleX(${bounded / 100})`;
  },

  resetProgress() {
    const input = this.el.querySelector("[data-transfer-file]");
    if (input) input.value = "";
    const progress = this.el.querySelector("[data-transfer-progress]");
    if (progress) progress.classList.add("hidden");
  }
};

// Boot
const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {
    TimelineScroll,
    KanbanSortable,
    Toast,
    OrgChartExport,
    Combobox,
    UserMenu,
    ColorSwatchPicker,
    AdapterConfigFields,
    DatePicker,
    IssueGateCleanup,
    InfiniteScroll,
    CopyToClipboard,
    CompanyImportTransfer
  }
});

liveSocket.connect();
window.liveSocket = liveSocket;

// Slim terracotta progress bar along the top during LiveView navigation.
// Pure transform animation (GPU-cheap); appears only when loading takes
// longer than 120ms so patches don't flicker it.
const progressBar = document.createElement("div");
progressBar.setAttribute("aria-hidden", "true");
progressBar.style.cssText = [
  "position:fixed", "top:0", "left:0", "right:0", "height:2px", "z-index:80",
  "background:linear-gradient(90deg, var(--color-primary), var(--color-primary-hover))",
  "transform-origin:left", "transform:scaleX(0)", "opacity:0",
  "transition:transform 400ms cubic-bezier(0.16,1,0.3,1), opacity 200ms ease",
  "pointer-events:none"
].join(";");
document.body.appendChild(progressBar);

let progressTimer = null;
window.addEventListener("phx:page-loading-start", () => {
  clearTimeout(progressTimer);
  progressTimer = setTimeout(() => {
    progressBar.style.opacity = "1";
    progressBar.style.transform = "scaleX(0.7)";
  }, 120);
});
window.addEventListener("phx:page-loading-stop", () => {
  clearTimeout(progressTimer);
  if (progressBar.style.opacity === "1") {
    progressBar.style.transform = "scaleX(1)";
    setTimeout(() => {
      progressBar.style.opacity = "0";
      setTimeout(() => { progressBar.style.transform = "scaleX(0)"; }, 200);
    }, 150);
  }
});

function createSwarmHiddenInput(name, value) {
  const input = document.createElement('input');
  input.type = 'hidden';
  input.name = name;
  input.value = value || '';
  return input;
}

function swarmSelectLabel(select, fallback) {
  if (!select) return fallback;
  const option = select.options[select.selectedIndex];
  return (option?.textContent || select.value || fallback).trim();
}

function swarmOptionLabel(select, value, fallback) {
  if (!select) return fallback || value || '';
  const option = Array.from(select.options).find((option) => option.value === value);
  return (option?.textContent || fallback || value || '').trim();
}

function swarmNextIndex(config) {
  const current = Number.parseInt(config.dataset.swarmNextIndex || '0', 10);
  if (Number.isFinite(current)) return current;
  return 0;
}

function dispatchSwarmCompositionChange(config) {
  const marker = config.querySelector('[data-swarm-change-marker]');
  if (!marker) return;
  marker.value = String(Date.now());
  marker.dispatchEvent(new Event('input', {bubbles: true}));
  marker.dispatchEvent(new Event('change', {bubbles: true}));
}

function updateSwarmCompositionCount(config) {
  const rows = Array.from(config.querySelectorAll('[data-swarm-choice-row]'));
  const scope = config.closest('section') || config;
  scope.querySelectorAll('[data-swarm-count]').forEach((el) => {
    el.textContent = String(rows.length);
  });
  const emptyRow = config.querySelector('[data-swarm-empty-row]');
  if (emptyRow) emptyRow.classList.toggle('hidden', rows.length > 0);
}

function swarmRowHiddenInput(row, field) {
  const byData = row.querySelector(`[data-swarm-row-${field}-input]`);
  if (byData) return byData;

  const suffix = field === 'reasoning' ? 'reasoning_effort' : field;
  return row.querySelector(`input[name$="[${suffix}]"]`);
}

function swarmRowLabel(row, field) {
  return row.querySelector(`[data-swarm-row-${field}-label]`);
}

function swarmRowValue(row, field) {
  const input = swarmRowHiddenInput(row, field);
  return input ? input.value : '';
}

function setSwarmRowValue(row, field, value) {
  const input = swarmRowHiddenInput(row, field);
  if (input) input.value = value || '';
}

function updateSwarmRowLabels(config, row) {
  const harnessSelect = config.querySelector('[data-swarm-choice-harness]');
  const reasoningSelect = config.querySelector('[data-swarm-choice-reasoning]');
  const harness = swarmRowValue(row, 'harness') || 'openai_chat';
  const model = (swarmRowValue(row, 'model') || '').trim();
  const reasoning = swarmRowValue(row, 'reasoning') || 'auto';

  const harnessLabel = swarmRowLabel(row, 'harness');
  if (harnessLabel) harnessLabel.textContent = swarmOptionLabel(harnessSelect, harness, harness);

  const modelLabel = swarmRowLabel(row, 'model');
  if (modelLabel) modelLabel.textContent = model || 'Runtime default';

  const reasoningLabel = swarmRowLabel(row, 'reasoning');
  if (reasoningLabel) {
    reasoningLabel.textContent = swarmOptionLabel(reasoningSelect, reasoning, reasoning);
  }
}

function createSwarmRemoveButton() {
  const removeButton = document.createElement('button');
  removeButton.type = 'button';
  removeButton.dataset.swarmRemoveRow = '';
  removeButton.className =
    'inline-flex h-7 w-7 items-center justify-center rounded-md text-text-tertiary hover:bg-surface-hover hover:text-text-primary';
  removeButton.setAttribute('aria-label', 'Remove swarm runtime choice');
  const icon = document.createElement('span');
  icon.className = 'hero-x-mark-mini h-4 w-4';
  removeButton.appendChild(icon);
  return removeButton;
}

function createSwarmEditButton() {
  const button = document.createElement('button');
  button.type = 'button';
  button.dataset.swarmEditRow = '';
  button.className =
    'inline-flex h-7 w-7 items-center justify-center rounded-md text-text-tertiary hover:bg-surface-hover hover:text-text-primary';
  button.setAttribute('aria-label', 'Edit swarm runtime choice');
  const icon = document.createElement('span');
  icon.className = 'hero-pencil-square-mini h-4 w-4';
  button.appendChild(icon);
  return button;
}

function createSwarmDoneButton() {
  const button = document.createElement('button');
  button.type = 'button';
  button.dataset.swarmDoneEdit = '';
  button.className =
    'inline-flex h-7 items-center justify-center rounded-md border border-cyan-500/25 bg-cyan-500/10 px-2 text-[10px] font-590 uppercase text-cyan-100 hover:bg-cyan-500/15';
  button.textContent = 'Done';
  return button;
}

function createSwarmInlineSelect(sourceSelect, value, dataName) {
  const select = document.createElement('select');
  select.className =
    'block h-7 w-full rounded-md border border-cyan-500/35 bg-canvas px-2 text-xs text-text-primary focus:border-cyan-400 focus:ring-cyan-500/30';
  select.dataset[dataName] = '';

  if (sourceSelect) {
    Array.from(sourceSelect.options).forEach((sourceOption) => {
      const option = document.createElement('option');
      option.value = sourceOption.value;
      option.textContent = sourceOption.textContent;
      select.appendChild(option);
    });
  }

  select.value = value || '';
  return select;
}

function createSwarmInlineModelInput(sourceInput, value) {
  const input = document.createElement('input');
  input.type = 'text';
  input.value = value || '';
  input.placeholder = 'runtime default or provider model';
  input.className =
    'block h-7 w-full rounded-md border border-cyan-500/35 bg-canvas px-2 font-mono text-xs text-text-primary placeholder:font-sans placeholder:text-text-quaternary focus:border-cyan-400 focus:ring-cyan-500/30';
  input.dataset.swarmInlineModel = '';

  const listId = sourceInput?.getAttribute('list');
  if (listId) input.setAttribute('list', listId);

  return input;
}

function exitSwarmRowEdit(config, row) {
  if (!row || row.dataset.swarmEditing !== 'true') return;

  row
    .querySelectorAll(
      '[data-swarm-inline-harness], [data-swarm-inline-model], [data-swarm-inline-reasoning]'
    )
    .forEach((control) => control.remove());

  row
    .querySelectorAll(
      '[data-swarm-row-harness-label], [data-swarm-row-model-label], [data-swarm-row-reasoning-label]'
    )
    .forEach((label) => label.classList.remove('hidden'));

  const actionCell = row.querySelector('[data-swarm-row-actions]');
  if (actionCell) {
    actionCell.innerHTML = '';
    actionCell.appendChild(createSwarmEditButton());
    actionCell.appendChild(createSwarmRemoveButton());
  }

  delete row.dataset.swarmEditing;
  row.classList.remove('bg-cyan-500/10', 'ring-1', 'ring-cyan-500/30');
  updateSwarmRowLabels(config, row);
}

function enterSwarmRowEdit(config, row) {
  if (!config || !row || row.dataset.swarmEditing === 'true') return;

  config.querySelectorAll('[data-swarm-choice-row][data-swarm-editing="true"]').forEach((openRow) => {
    if (openRow !== row) exitSwarmRowEdit(config, openRow);
  });

  const harnessSelect = config.querySelector('[data-swarm-choice-harness]');
  const modelInput = config.querySelector('[data-swarm-choice-model]');
  const reasoningSelect = config.querySelector('[data-swarm-choice-reasoning]');
  const harnessLabel = swarmRowLabel(row, 'harness');
  const modelLabel = swarmRowLabel(row, 'model');
  const reasoningLabel = swarmRowLabel(row, 'reasoning');

  if (!harnessLabel || !modelLabel || !reasoningLabel) return;

  row.dataset.swarmEditing = 'true';
  row.classList.add('bg-cyan-500/10', 'ring-1', 'ring-cyan-500/30');

  harnessLabel.classList.add('hidden');
  modelLabel.classList.add('hidden');
  reasoningLabel.classList.add('hidden');

  const inlineHarness = createSwarmInlineSelect(
    harnessSelect,
    swarmRowValue(row, 'harness'),
    'swarmInlineHarness'
  );
  const inlineModel = createSwarmInlineModelInput(modelInput, swarmRowValue(row, 'model'));
  const inlineReasoning = createSwarmInlineSelect(
    reasoningSelect,
    swarmRowValue(row, 'reasoning'),
    'swarmInlineReasoning'
  );

  harnessLabel.insertAdjacentElement('afterend', inlineHarness);
  modelLabel.insertAdjacentElement('afterend', inlineModel);
  reasoningLabel.insertAdjacentElement('afterend', inlineReasoning);

  inlineHarness.addEventListener('change', () => {
    setSwarmRowValue(row, 'harness', inlineHarness.value);
    updateSwarmRowLabels(config, row);
  });

  inlineModel.addEventListener('input', () => {
    setSwarmRowValue(row, 'model', inlineModel.value.trim());
    updateSwarmRowLabels(config, row);
  });

  inlineReasoning.addEventListener('change', () => {
    setSwarmRowValue(row, 'reasoning', inlineReasoning.value);
    updateSwarmRowLabels(config, row);
  });

  const actionCell = row.querySelector('[data-swarm-row-actions]');
  if (actionCell) {
    actionCell.innerHTML = '';
    actionCell.appendChild(createSwarmDoneButton());
    actionCell.appendChild(createSwarmRemoveButton());
  }

  requestAnimationFrame(() => inlineModel.focus());
}

function appendSwarmCompositionRow(config) {
  const harnessSelect = config.querySelector('[data-swarm-choice-harness]');
  const modelInput = config.querySelector('[data-swarm-choice-model]');
  const reasoningSelect = config.querySelector('[data-swarm-choice-reasoning]');
  const tbody = config.querySelector('[data-swarm-rows]');
  if (!harnessSelect || !modelInput || !reasoningSelect || !tbody) return;

  const index = swarmNextIndex(config);
  const harness = harnessSelect.value || 'openai_chat';
  const model = (modelInput.value || '').trim();
  const reasoning = reasoningSelect.value || 'auto';
  const row = document.createElement('tr');
  row.dataset.swarmChoiceRow = '';
  row.dataset.swarmEditableRow = '';
  row.tabIndex = 0;
  row.className =
    'cursor-pointer transition hover:bg-surface-hover/50 focus:outline-none focus:ring-1 focus:ring-cyan-500/40';

  const harnessCell = document.createElement('td');
  harnessCell.className = 'min-w-[180px] px-3 py-2 align-middle font-510 text-text-primary';
  harnessCell.appendChild(createSwarmHiddenInput(`swarm[mix_rows][${index}][enabled]`, 'true'));
  const harnessHidden = createSwarmHiddenInput(`swarm[mix_rows][${index}][harness]`, harness);
  harnessHidden.dataset.swarmRowHarnessInput = '';
  harnessCell.appendChild(harnessHidden);
  const harnessLabel = document.createElement('span');
  harnessLabel.dataset.swarmRowHarnessLabel = '';
  harnessLabel.textContent = swarmSelectLabel(harnessSelect, harness);
  harnessCell.appendChild(harnessLabel);

  const modelCell = document.createElement('td');
  modelCell.className = 'min-w-[180px] px-3 py-2 align-middle font-mono text-text-secondary';
  const modelHidden = createSwarmHiddenInput(`swarm[mix_rows][${index}][model]`, model);
  modelHidden.dataset.swarmRowModelInput = '';
  modelCell.appendChild(modelHidden);
  const modelLabel = document.createElement('span');
  modelLabel.dataset.swarmRowModelLabel = '';
  modelLabel.textContent = model || 'Runtime default';
  modelCell.appendChild(modelLabel);

  const reasoningCell = document.createElement('td');
  reasoningCell.className =
    'w-[120px] min-w-[120px] px-3 py-2 align-middle text-text-secondary';
  const reasoningHidden = createSwarmHiddenInput(
    `swarm[mix_rows][${index}][reasoning_effort]`,
    reasoning
  );
  reasoningHidden.dataset.swarmRowReasoningInput = '';
  reasoningCell.appendChild(reasoningHidden);
  const reasoningLabel = document.createElement('span');
  reasoningLabel.dataset.swarmRowReasoningLabel = '';
  reasoningLabel.textContent = swarmSelectLabel(reasoningSelect, reasoning);
  reasoningCell.appendChild(reasoningLabel);

  const actionCell = document.createElement('td');
  actionCell.className =
    'w-28 min-w-[7rem] whitespace-nowrap px-2 py-2 text-right align-middle';
  const actionWrap = document.createElement('div');
  actionWrap.className = 'flex h-7 items-center justify-end gap-1 whitespace-nowrap';
  actionWrap.dataset.swarmRowActions = '';
  actionWrap.appendChild(createSwarmEditButton());
  actionWrap.appendChild(createSwarmRemoveButton());
  actionCell.appendChild(actionWrap);

  row.appendChild(harnessCell);
  row.appendChild(modelCell);
  row.appendChild(reasoningCell);
  row.appendChild(actionCell);

  const emptyRow = config.querySelector('[data-swarm-empty-row]');
  tbody.insertBefore(row, emptyRow || null);
  config.dataset.swarmNextIndex = String(index + 1);
  updateSwarmCompositionCount(config);
  enterSwarmRowEdit(config, row);
}

document.addEventListener('click', (e) => {
  const addButton = e.target.closest('[data-swarm-add-row]');
  if (addButton) {
    e.preventDefault();
    const config = addButton.closest('[data-swarm-composition]');
    if (config) appendSwarmCompositionRow(config);
    return;
  }

  const doneButton = e.target.closest('[data-swarm-done-edit]');
  if (doneButton) {
    e.preventDefault();
    const config = doneButton.closest('[data-swarm-composition]');
    const row = doneButton.closest('[data-swarm-choice-row]');
    if (config && row) {
      exitSwarmRowEdit(config, row);
      dispatchSwarmCompositionChange(config);
    }
    return;
  }

  const editButton = e.target.closest('[data-swarm-edit-row]');
  if (editButton) {
    e.preventDefault();
    const config = editButton.closest('[data-swarm-composition]');
    const row = editButton.closest('[data-swarm-choice-row]');
    if (config && row) enterSwarmRowEdit(config, row);
    return;
  }

  const removeButton = e.target.closest('[data-swarm-remove-row]');
  if (removeButton) {
    e.preventDefault();
    const config = removeButton.closest('[data-swarm-composition]');
    const row = removeButton.closest('[data-swarm-choice-row]');
    if (row) row.remove();
    if (config) {
      updateSwarmCompositionCount(config);
      dispatchSwarmCompositionChange(config);
    }
    return;
  }

  const row = e.target.closest('[data-swarm-editable-row]');
  if (row && !e.target.closest('button, input, select, textarea, a')) {
    const config = row.closest('[data-swarm-composition]');
    if (config) enterSwarmRowEdit(config, row);
  }
});

document.addEventListener('keydown', (e) => {
  const row = e.target.closest?.('[data-swarm-editable-row]');
  if (!row) return;

  const config = row.closest('[data-swarm-composition]');
  if (!config) return;

  if (e.key === 'Escape' && row.dataset.swarmEditing === 'true') {
    e.preventDefault();
    exitSwarmRowEdit(config, row);
    return;
  }

  if (
    (e.key === 'Enter' || e.key === ' ') &&
    e.target === row &&
    row.dataset.swarmEditing !== 'true'
  ) {
    e.preventDefault();
    enterSwarmRowEdit(config, row);
  }
});

// Quick-create issue modal: opened by `C` keystroke. Cancel button and
// backdrop close it; submit goes through the standard form POST so we
// don't need a separate AJAX path.
function openQuickCreate() {
  const modal = document.getElementById('quick-create-modal');
  if (!modal) return;
  modal.classList.remove('hidden');
  const input = document.getElementById('quick-create-title');
  if (input) {
    input.value = '';
    requestAnimationFrame(() => input.focus());
  }
}
window.openQuickCreate = openQuickCreate;

function initQuickCreate() {
  const modal = document.getElementById('quick-create-modal');
  if (!modal || modal.dataset.qcInit) return;
  modal.dataset.qcInit = '1';

  const cancelBtn = modal.querySelector('[data-quick-create-cancel]');
  if (cancelBtn) {
    cancelBtn.addEventListener('click', () => modal.classList.add('hidden'));
  }
  modal.addEventListener('click', (e) => {
    if (e.target === modal) modal.classList.add('hidden');
  });
}

// ---------------------------------------------------------------------------
// Sidebar collapsible sections (Projects / Agents) + inline "Show N more".
//
// The nav rail lives in the conn-rendered root layout, so state is client-side:
// collapse + show-more toggles persist in localStorage and are re-applied on
// load. LiveView live-nav keeps the layout mounted, so in-session toggles also
// survive navigation without touching storage. Markup: a <div data-nav-section>
// wraps a <button data-nav-toggle> (with a <span data-nav-chevron>) + a
// <div data-nav-body> of rows; overflow rows carry data-nav-overflow + `hidden`
// and a <button data-nav-show-more> reveals them.
// ---------------------------------------------------------------------------
const NAV_COLLAPSE_KEY = 'cympho.nav.collapsed';
const NAV_EXPAND_KEY = 'cympho.nav.expanded';

function readNavState(key) {
  try {
    return JSON.parse(localStorage.getItem(key) || '{}') || {};
  } catch (_e) {
    return {};
  }
}

function writeNavState(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch (_e) {
    /* storage disabled — in-session DOM state still works */
  }
}

function setNavCollapsed(section, collapsed) {
  section.querySelector('[data-nav-body]')?.classList.toggle('hidden', collapsed);
  section.querySelector('[data-nav-chevron]')?.classList.toggle('-rotate-90', collapsed);
  section.querySelector('[data-nav-toggle]')?.setAttribute('aria-expanded', String(!collapsed));
}

function setNavExpanded(section, expanded) {
  section.querySelectorAll('[data-nav-overflow]').forEach((row) => {
    row.classList.toggle('hidden', !expanded);
  });
  section.querySelector('[data-nav-more]')?.classList.toggle('hidden', expanded);
  section.querySelector('[data-nav-less]')?.classList.toggle('hidden', !expanded);
}

function applyNavSectionState() {
  const collapsed = readNavState(NAV_COLLAPSE_KEY);
  const expanded = readNavState(NAV_EXPAND_KEY);
  document.querySelectorAll('[data-nav-section]').forEach((section) => {
    const key = section.dataset.navSection;
    setNavCollapsed(section, collapsed[key] === true);
    setNavExpanded(section, expanded[key] === true);
  });
}

document.addEventListener('click', (e) => {
  const toggle = e.target.closest('[data-nav-toggle]');
  if (toggle) {
    const section = toggle.closest('[data-nav-section]');
    const key = section?.dataset.navSection;
    if (!key) return;
    const state = readNavState(NAV_COLLAPSE_KEY);
    state[key] = !(state[key] === true);
    writeNavState(NAV_COLLAPSE_KEY, state);
    setNavCollapsed(section, state[key]);
    return;
  }
  const more = e.target.closest('[data-nav-show-more]');
  if (more) {
    const section = more.closest('[data-nav-section]');
    const key = section?.dataset.navSection;
    if (!key) return;
    const state = readNavState(NAV_EXPAND_KEY);
    state[key] = !(state[key] === true);
    writeNavState(NAV_EXPAND_KEY, state);
    setNavExpanded(section, state[key]);
  }
});

// Initialize after DOM ready
document.addEventListener('DOMContentLoaded', () => {
  highlightActiveNav();
  applyNavSectionState();
  initCommandPalette();
  initCompanySwitcher();
  initSidebarMobile();
  initShortcutsModal();
  initQuickCreate();
  applyUIMode(currentUIMode());

  // Re-highlight on LiveView navigation
  window.addEventListener('phx:navigate', () => {
    window.requestAnimationFrame(() => {
      highlightActiveNav();
    });
  });
  window.addEventListener('phx:page-loading-stop', () => {
    window.requestAnimationFrame(() => {
      highlightActiveNav();
      applyNavSectionState();
      initCompanySwitcher();
      initQuickCreate();
      applyUIMode(currentUIMode());
    });
  });
});

// Sidebar mobile menu handlers
function initSidebarMobile() {
  const overlay = document.getElementById('sidebar-overlay');
  const sidebar = document.getElementById('sidebar');
  const mobileMenuBtn = document.querySelector('[data-mobile-menu-btn]');
  const desktopQuery = window.matchMedia('(min-width: 1024px)');

  if (!sidebar) return;

  const setSidebarOpen = (open) => {
    const desktop = desktopQuery.matches;
    const shouldOpen = desktop || open;

    sidebar.classList.toggle('-translate-x-full', !shouldOpen);

    if (shouldOpen) {
      sidebar.removeAttribute('inert');
      sidebar.removeAttribute('aria-hidden');
    } else {
      sidebar.setAttribute('inert', '');
      sidebar.setAttribute('aria-hidden', 'true');
    }

    if (overlay) {
      overlay.classList.toggle('hidden', desktop || !open);
    }

    if (mobileMenuBtn) {
      mobileMenuBtn.setAttribute('aria-expanded', open && !desktop ? 'true' : 'false');
    }
  };

  const syncSidebarForViewport = () => {
    setSidebarOpen(desktopQuery.matches);
  };

  syncSidebarForViewport();

  if (overlay) {
    overlay.addEventListener('click', () => {
      setSidebarOpen(false);
    });
  }

  if (mobileMenuBtn) {
    mobileMenuBtn.addEventListener('click', () => {
      setSidebarOpen(true);
    });
  }

  sidebar.addEventListener('click', (event) => {
    if (desktopQuery.matches) return;

    if (event.target.closest('a[href], [data-quick-create-trigger]')) {
      setSidebarOpen(false);
    }
  });

  if (desktopQuery.addEventListener) {
    desktopQuery.addEventListener('change', syncSidebarForViewport);
  } else {
    desktopQuery.addListener(syncSidebarForViewport);
  }

  // Company switcher button in mobile header
  const companySwitcherBtn = document.querySelector('[data-company-switcher-btn]');
  if (companySwitcherBtn) {
    companySwitcherBtn.addEventListener('click', () => {
      if (window.openCompanySwitcher) {
        window.openCompanySwitcher();
      }
    });
  }
}

// Shortcuts modal handlers
function initShortcutsModal() {
  const shortcutsBtn = document.querySelector('[data-shortcuts-btn]');
  const shortcutsModal = document.getElementById('shortcuts-modal');
  const closeShortcutsBtn = document.querySelector('[data-close-shortcuts-btn]');

  if (shortcutsBtn && shortcutsModal) {
    shortcutsBtn.addEventListener('click', () => {
      shortcutsModal.classList.remove('hidden');
    });
  }

  if (closeShortcutsBtn && shortcutsModal) {
    closeShortcutsBtn.addEventListener('click', () => {
      shortcutsModal.classList.add('hidden');
    });
  }

  // Close on backdrop click
  if (shortcutsModal) {
    shortcutsModal.addEventListener('click', (e) => {
      if (e.target === shortcutsModal) {
        shortcutsModal.classList.add('hidden');
      }
    });
  }
}

// Also highlight on popstate (browser back/forward)
window.addEventListener('popstate', highlightActiveNav);

// Keyboard shortcuts
document.addEventListener('keydown', handleKeydown);
