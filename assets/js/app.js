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

  // Cmd/Ctrl+K opens command palette
  if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
    e.preventDefault();
    const palette = document.getElementById('command-palette');
    if (palette) {
      palette.classList.remove('hidden');
      const input = document.getElementById('command-input');
      if (input) {
        input.value = '';
        input.focus();
        // Reset search filter
        const results = document.getElementById('command-results');
        if (results) {
          results.querySelectorAll('.command-item').forEach(item => {
            item.style.display = '';
          });
        }
      }
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

// Boot
const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {KanbanSortable}
});

liveSocket.connect();
window.liveSocket = liveSocket;

// Initialize after DOM ready
document.addEventListener('DOMContentLoaded', () => {
  highlightActiveNav();
  initCommandPalette();

  // Re-highlight on LiveView navigation
  liveSocket.addEventListener('phx:navigate', highlightActiveNav);
  liveSocket.addEventListener('phx:page-loading-stop', highlightActiveNav);
});

// Also highlight on popstate (browser back/forward)
window.addEventListener('popstate', highlightActiveNav);

// Keyboard shortcuts
document.addEventListener('keydown', handleKeydown);
