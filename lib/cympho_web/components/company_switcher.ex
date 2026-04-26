defmodule CymphoWeb.Components.CompanySwitcher do
  use Phoenix.LiveComponent
  alias Cympho.Companies

  attr :companies, :list, default: []
  attr :current_company_id, :string, default: nil
  attr :return_to, :string, default: nil
  attr :id, :string, default: "company-switcher"

  def mount(socket) do
    {:ok, assign(socket, :search_query, "")}
  end

  def render(assigns) do
    ~H"""
    <div id={@id} class="hidden" data-return-to={@return_to}>
      <div id="company-switcher-modal" class="hidden fixed inset-0 z-[70] flex items-start justify-center pt-[15vh] bg-black/50" role="dialog" aria-modal="true" aria-labelledby="company-switcher-title">
        <div class="bg-panel border border-border rounded-panel shadow-dialog w-full max-w-lg mx-4 overflow-hidden">
          <div id="company-switcher-title" class="flex items-center gap-3 px-4 border-b border-border-subtle">
            <svg class="w-4 h-4 text-text-quaternary shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4"/>
            </svg>
            <input
              type="text"
              id="company-switcher-search"
              placeholder="Search companies..."
              class="flex-1 bg-transparent text-text-primary text-sm py-3.5 placeholder:text-text-quaternary focus:outline-none"
              autocomplete="off"
              phx-blur="update_search"
              phx-keyup="update_search"
              value={@search_query}
              name="query"
            />
            <kbd class="text-[10px] px-1.5 py-0.5 bg-white/[0.05] border border-border rounded text-text-quaternary shrink-0">ESC</kbd>
          </div>
          <div id="company-switcher-results" class="max-h-72 overflow-y-auto p-2">
            <%= if @companies == [] do %>
              <div class="px-3 py-8 text-center text-text-secondary text-sm">
                <svg class="w-8 h-8 mx-auto mb-2 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4"/>
                </svg>
                <p>No companies found</p>
              </div>
            <% else %>
              <%= for company <- filtered_companies(@companies, @search_query) do %>
                <.company_item
                  company={company}
                  is_current={company.id == @current_company_id}
                />
              <% end %>
              <%= if filtered_companies(@companies, @search_query) == [] do %>
                <div class="px-3 py-8 text-center text-text-secondary text-sm">
                  <p>No companies match your search</p>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("close_switcher", _, socket) do
    {:noreply, socket}
  end

  def handle_event("switch_company", %{"id" => company_id}, socket) do
    return_to = socket.assigns.return_to || "/"

    {:noreply,
     socket
     |> push_redirect(to: "/switch-company/#{company_id}?return_to=#{URI.encode_www_form(return_to)}")}
  end

  def handle_event("update_search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :search_query, query)}
  end

  attr :company, :map, required: true
  attr :is_current, :boolean, default: false

  defp company_item(assigns) do
    ~H"""
    <div
      class={[
        "flex items-center gap-3 px-3 py-2.5 rounded-md text-sm cursor-pointer transition-colors",
        @is_current && "bg-white/[0.06] text-text-primary",
        !@is_current && "text-text-secondary hover:bg-white/[0.04] hover:text-text-primary"
      ]}
      phx-click={JS.push("switch_company", value: %{id: @company.id})}
    >
      <div class="w-8 h-8 rounded-lg overflow-hidden border-l-2 border-brand flex items-center justify-center shrink-0 bg-brand/10">
        <img :if={@company.logo_url} src={@company.logo_url} alt={@company.name} class="w-full h-full object-cover" />
        <span :if={!@company.logo_url} class="text-sm font-590 text-brand">
          <%= company_initials(@company.name) %>
        </span>
      </div>
      <div class="flex-1 min-w-0">
        <div class="font-510 truncate"><%= @company.name %></div>
        <%= if @is_current do %>
          <div class="text-xs text-text-quaternary">Current company</div>
        <% end %>
      </div>
      <%= if @is_current do %>
        <svg class="w-4 h-4 text-brand shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
        </svg>
      <% end %>
    </div>
    """
  end

  defp company_initials(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp company_initials(_), do: "?"

  defp filtered_companies(companies, nil), do: companies
  defp filtered_companies(companies, ""), do: companies
  defp filtered_companies(companies, query) do
    lower_query = String.downcase(query)

    Enum.filter(companies, fn company ->
      String.contains?(String.downcase(company.name), lower_query)
    end)
  end
end
