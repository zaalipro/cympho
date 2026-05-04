import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// Cympho ships dark-only per DESIGN.md. Theme toggle was removed; this
// noop preserves the global symbol so any stale inline handlers still in
// the wild don't throw before they're cleaned up.
window.toggleTheme = function() {};

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
          ghostClass: "opacity-30",
          dragClass: "rotate-2",
          animation: 150,
          filter: "a, button, input, textarea, select, [data-no-drag]",
          preventOnFilter: false,
          onStart(evt) {
            evt.item.classList.add("kanban-card-dragging");
          },
          onEnd(evt) {
            evt.item.classList.remove("kanban-card-dragging");
            const issueId = evt.item.dataset.issueId;
            const toStatus = evt.to.dataset.kanbanColumn;
            const fromStatus = evt.from.dataset.kanbanColumn;
            if (fromStatus === toStatus) return;
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
    const isActive = path === navPath || path.startsWith(navPath + '/');
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
    const isActive = path === navPath || path.startsWith(navPath + '/');
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

// Keyboard shortcuts
const GOTO_KEYS = {
  'i': '/issues',
  'p': '/projects',
  'k': '/kanban',
  'a': '/agents',
  'g': '/goals',
  'd': '/dashboard',
  's': '/settings',
};

let gotoBuffer = '';
let gotoTimer = null;

function handleKeydown(e) {
  const target = e.target;
  const isInput = target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.tagName === 'SELECT' || target.isContentEditable;

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

  // Don't trigger shortcuts when typing in inputs
  if (isInput) return;

  // Cmd/Ctrl+K opens command palette
  if ((e.metaKey || e.ctrlKey) && e.key === 'k' && !e.shiftKey) {
    e.preventDefault();
    const palette = document.getElementById('command-palette');
    if (palette) {
      palette.classList.toggle('hidden');
      const input = document.getElementById('command-input');
      if (input && !palette.classList.contains('hidden')) {
        input.value = '';
        input.focus();
      }
    }
    return;
  }

  // Cmd/Ctrl+K opens company switcher
  if ((e.metaKey || e.ctrlKey) && e.key === 'K') {
    e.preventDefault();
    if (window.openCompanySwitcher) {
      window.openCompanySwitcher();
    }
    return;
  }

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

  // G prefix for navigation (G then another key)
  if (e.key === 'g' && !e.metaKey && !e.ctrlKey) {
    gotoBuffer = 'g';
    clearTimeout(gotoTimer);
    gotoTimer = setTimeout(() => { gotoBuffer = ''; }, 1000);
    return;
  }

  if (gotoBuffer === 'g') {
    const url = GOTO_KEYS[e.key];
    if (url) {
      e.preventDefault();
      window.location.href = url;
    }
    gotoBuffer = '';
    clearTimeout(gotoTimer);
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
      const btn = e.target.closest('[data-action]');
      if (!btn) return;
      const action = btn.dataset.action;
      this._setOpen(false);
      if (action === 'open-shortcuts') {
        const m = document.getElementById('shortcuts-modal');
        if (m) m.classList.remove('hidden');
      } else if (action === 'open-command-palette') {
        const p = document.getElementById('command-palette');
        if (p) {
          p.classList.remove('hidden');
          const input = document.getElementById('command-input');
          if (input) requestAnimationFrame(() => input.focus());
        }
      }
    };

    this.trigger.addEventListener('click', this.toggle);
    document.addEventListener('click', this.outside);
    document.addEventListener('keydown', this.escape);
    this.popover.addEventListener('click', this.handleAction);
  },
  destroyed() {
    document.removeEventListener('click', this.outside);
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

// Sidebar primary "New issue" button — open the quick-create modal.
document.addEventListener('click', (e) => {
  const trig = e.target.closest('[data-quick-create-trigger]');
  if (trig && typeof window.openQuickCreate === 'function') {
    e.preventDefault();
    window.openQuickCreate();
  }
});

// Boot
const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {TimelineScroll, KanbanSortable, Toast, OrgChartExport, Combobox, UserMenu, ColorSwatchPicker}
});

liveSocket.connect();
window.liveSocket = liveSocket;

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

// Initialize after DOM ready
document.addEventListener('DOMContentLoaded', () => {
  highlightActiveNav();
  initCommandPalette();
  initCompanySwitcher();
  initSidebarMobile();
  initShortcutsModal();
  initQuickCreate();

  // Re-highlight on LiveView navigation
  window.addEventListener('phx:navigate', () => {
    window.requestAnimationFrame(() => {
      highlightActiveNav();
    });
  });
  window.addEventListener('phx:page-loading-stop', () => {
    window.requestAnimationFrame(() => {
      highlightActiveNav();
      initCompanySwitcher();
      initQuickCreate();
    });
  });
});

// Sidebar mobile menu handlers
function initSidebarMobile() {
  const overlay = document.getElementById('sidebar-overlay');
  const sidebar = document.getElementById('sidebar');
  const mobileMenuBtn = document.querySelector('[data-mobile-menu-btn]');

  if (overlay) {
    overlay.addEventListener('click', () => {
      sidebar.classList.add('-translate-x-full');
      overlay.classList.add('hidden');
    });
  }

  if (mobileMenuBtn) {
    mobileMenuBtn.addEventListener('click', () => {
      sidebar.classList.remove('-translate-x-full');
      overlay.classList.remove('hidden');
    });
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
