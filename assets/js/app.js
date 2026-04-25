import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

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
    const columns = this.el.querySelectorAll("[data-kanban-column]");
    columns.forEach(column => {
      const sortable = new window.Sortable(column, {
        group: "kanban",
        ghostClass: "opacity-30",
        dragClass: "rotate-2",
        animation: 150,
        onEnd(evt) {
          const issueId = evt.item.dataset.issueId;
          const toStatus = evt.to.dataset.kanbanColumn;
          const fromStatus = evt.from.dataset.kanbanColumn;
          if (fromStatus === toStatus) return;
          hook.pushEvent("transition_issue", {id: issueId, to_status: toStatus});
        }
      });
      this.sortables.push(sortable);
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
  if (!input || !results) return;

  input.addEventListener('input', (e) => {
    const query = e.target.value.toLowerCase().trim();
    const items = results.querySelectorAll('.command-item');

    items.forEach(item => {
      const text = item.textContent.toLowerCase();
      item.style.display = !query || text.includes(query) ? '' : 'none';
    });
  });
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

  // Cmd/Ctrl+K opens company switcher
  if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
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
      resultsList.innerHTML = '';
      emptyState.classList.remove('hidden');
      return;
    }

    emptyState.classList.add('hidden');
    resultsList.innerHTML = filtered.map(company => {
      const isCurrent = company.id === currentCompanyId;
      return `
        <div
          class="flex items-center gap-3 px-3 py-2.5 rounded-md text-sm cursor-pointer transition-colors ${isCurrent ? 'bg-white/[0.06] text-text-primary' : 'text-text-secondary hover:bg-white/[0.04] hover:text-text-primary'}"
          data-company-id="${company.id}"
        >
          <div class="w-8 h-8 rounded-lg overflow-hidden border-l-2 border-brand flex items-center justify-center shrink-0 bg-brand/10">
            ${company.logo_url
              ? `<img src="${company.logo_url}" alt="${company.name}" class="w-full h-full object-cover" />`
              : `<span class="text-sm font-590 text-brand">${companyInitials(company.name)}</span>`
            }
          </div>
          <div class="flex-1 min-w-0">
            <div class="font-510 truncate">${company.name}</div>
            ${isCurrent ? '<div class="text-xs text-text-quaternary">Current company</div>' : ''}
          </div>
          ${isCurrent
            ? '<svg class="w-4 h-4 text-brand shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/></svg>'
            : ''
          }
        </div>
      `;
    }).join('');

    // Add click handlers
    resultsList.querySelectorAll('[data-company-id]').forEach(el => {
      el.addEventListener('click', () => {
        const companyId = el.dataset.companyId;
        const returnTo = encodeURIComponent(window.location.pathname);
        window.location.href = `/switch-company/${companyId}?return_to=${returnTo}`;
      });
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

// CompanySwitcher hook (deprecated, kept for backwards compatibility)
const CompanySwitcher = {
  mounted() {
    // This hook is no longer needed, functionality moved to initCompanySwitcher
  },
  destroyed() {
    // Cleanup if needed
  }
};

// Boot
const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {KanbanSortable, CompanySwitcher}
});

liveSocket.connect();
window.liveSocket = liveSocket;

// Initialize after DOM ready
document.addEventListener('DOMContentLoaded', () => {
  highlightActiveNav();
  initCommandPalette();
  initCompanySwitcher();

  // Re-highlight on LiveView navigation
  liveSocket.addEventListener('phx:navigate', highlightActiveNav);
  liveSocket.addEventListener('phx:page-loading-stop', () => {
    highlightActiveNav();
    initCompanySwitcher();
  });
});

// Also highlight on popstate (browser back/forward)
window.addEventListener('popstate', highlightActiveNav);

// Keyboard shortcuts
document.addEventListener('keydown', handleKeydown);
