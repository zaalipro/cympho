import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

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

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {KanbanSortable}
});

liveSocket.connect();
window.liveSocket = liveSocket;
