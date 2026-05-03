defmodule CymphoWeb.Components.CompanyRail do
  use Phoenix.Component

  attr :company, :map, default: nil
  attr :rest, :global

  def company_rail(assigns) do
    ~H"""
    <div class="h-14 flex items-center justify-between px-3 border-b border-border" {@rest}>
      <button
        type="button"
        class="flex items-center gap-2 hover:bg-surface-hover px-2 py-1.5 transition-colors rounded-md flex-1 min-w-0"
        onclick="window.openCompanySwitcher && window.openCompanySwitcher()"
      >
        <.company_display company={@company} />
        <svg
          class="w-4 h-4 text-text-quaternary ml-auto"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </button>
    </div>
    """
  end

  attr :company, :map, default: nil

  def company_display(%{company: nil} = assigns) do
    ~H"""
    <span class="text-sm font-590 text-text-primary">Cympho</span>
    """
  end

  def company_display(%{company: company} = assigns) do
    assigns = assign(assigns, :company, company)

    ~H"""
    <div class="flex items-center gap-3">
      <div :if={@company.logo_url} class="w-6 h-6 rounded-md overflow-hidden">
        <img src={@company.logo_url} alt={@company.name} class="w-full h-full object-cover" />
      </div>
      <div
        :if={!@company.logo_url}
        class="w-6 h-6 rounded-md bg-brand/12 flex items-center justify-center"
      >
        <span class="text-[11px] font-590 text-brand">{company_initials(@company.name)}</span>
      </div>
      <span class="text-sm font-590 text-text-primary truncate hidden md:inline">
        {@company.name}
      </span>
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
end
