defmodule CymphoWeb.Components.CompanySwitcherStatic do
  use Phoenix.Component

  attr :companies, :list, default: []
  attr :current_company_id, :string, default: nil

  def company_switcher_static(assigns) do
    ~H"""
    <div id="company-switcher-wrapper" data-companies={Jason.encode!(@companies)} data-current-company-id={@current_company_id}>
      <div id="company-switcher-modal" class="hidden fixed inset-0 z-[70] flex items-start justify-center pt-[15vh] bg-black/50">
        <div class="bg-panel border border-border rounded-panel shadow-dialog w-full max-w-lg mx-4 overflow-hidden">
          <div class="flex items-center gap-3 px-4 border-b border-border-subtle">
            <svg class="w-4 h-4 text-text-quaternary shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4"/>
            </svg>
            <input
              type="text"
              id="company-switcher-search"
              placeholder="Search companies..."
              class="flex-1 bg-transparent text-text-primary text-sm py-3.5 placeholder:text-text-quaternary focus:outline-none"
              autocomplete="off"
            />
            <kbd class="text-[10px] px-1.5 py-0.5 bg-white/[0.05] border border-border rounded text-text-quaternary shrink-0">ESC</kbd>
          </div>
          <div id="company-switcher-results" class="max-h-72 overflow-y-auto p-2">
            <div class="px-3 py-8 text-center text-text-secondary text-sm hidden" id="company-switcher-empty">
              <svg class="w-8 h-8 mx-auto mb-2 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4"/>
              </svg>
              <p>No companies match your search</p>
            </div>
            <div id="company-switcher-list"></div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
