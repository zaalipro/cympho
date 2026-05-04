import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// Theme management
function initTheme() {
  const stored = localStorage.getItem('cympho-theme');
  if (stored === 'dark' || (!stored && window.matchMedia('(prefers-color-scheme: dark)').matches)) {
    document.documentElement.setAttribute('data-theme', 'dark');
  } else if (stored === 'light') {
    document.documentElement.setAttribute('data-theme', 'light');
  } else {
    document.documentElement.removeAttribute('data-theme');
  }
}

window.toggleTheme = function() {
  const currentTheme = document.documentElement.getAttribute('data-theme');
  const newTheme = currentTheme === 'dark' ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', newTheme);
  localStorage.setItem('cympho-theme', newTheme);
};

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

// Kanban drag-and-drop hook
const KanbanSortable = {
  mounted() {
    this.sortables = [];
    this._initSortables();
    this.handleEvent("shake_card", ({issue_id}) => {
      const card = this.el.querySelector(`[data-issue-id="${issue_id}"]`);
      if (card) {
        card.classList.add("phx-error-shake");
        setTimeout(() => card.classList.remove("phx-error-shake"), 600);
      }
    });
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
          onEnd(evt) {
            const issueId = evt.item.dataset.issueId;
            const toStatus = evt.to.dataset.kanbanColumn;
            const fromStatus = evt.from.dataset.kanbanColumn;
            if (fromStatus === toStatus) return;
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

  // C opens new issue
  if (e.key === 'c') {
    e.preventDefault();
    window.location.href = '/issues/new';
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

// Boot
const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {TimelineScroll, KanbanSortable, Toast}
});

liveSocket.connect();
window.liveSocket = liveSocket;

// Initialize after DOM ready
document.addEventListener('DOMContentLoaded', () => {
  initTheme();
  highlightActiveNav();
  initCommandPalette();
  initCompanySwitcher();
  initSidebarMobile();
  initShortcutsModal();

  // Re-highlight on LiveView navigation
  window.addEventListener('phx:navigate', () => {
    window.requestAnimationFrame(() => {
      initTheme();
      highlightActiveNav();
    });
  });
  window.addEventListener('phx:page-loading-stop', () => {
    window.requestAnimationFrame(() => {
      initTheme();
      highlightActiveNav();
      initCompanySwitcher();
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
