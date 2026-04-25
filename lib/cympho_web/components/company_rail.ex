defmodule CymphoWeb.Components.CompanyRail do
  use Phoenix.Component
  alias Cympho.Companies.Company

  attr :company, Company, required: true
  attr :collapsed, :boolean, default: false
  attr :rest, :global

  def company_rail(assigns) do
    ~H"""
    <div class="h-14 flex items-center justify-between px-4 border-b border-border-subtle" {@rest}>
      <.company_display company={@company} collapsed={@collapsed} />
      <.collapse_toggle collapsed={@collapsed} />
    </div>
    """
  end

  attr :company, :map, default: nil
  attr :collapsed, :boolean, default: false

  def company_display(%{company: nil}) do
    ~H"""
    <span class="text-lg font-590 tracking-tight text-text-primary">Cympho</span>
    """
  end

  def company_display(%{company: company, collapsed: true}) do
    ~H"""
    <div class="w-8 h-8 rounded-lg bg-brand/10 border-l-2 border-brand flex items-center justify-center">
      <span class="text-sm font-590 text-brand">{company_initials(company.name)}</span>
    </div>
    """
  end

  def company_display(%{company: company}) do
    ~H"""
    <div class="flex items-center gap-3">
      <div :if={company.logo_url} class="w-8 h-8 rounded-lg overflow-hidden border-l-2 border-brand">
        <img src={company.logo_url} alt={company.name} class="w-full h-full object-cover" />
      </div>
      <div :if={!company.logo_url} class="w-8 h-8 rounded-lg bg-brand/10 border-l-2 border-brand flex items-center justify-center">
        <span class="text-sm font-590 text-brand">{company_initials(company.name)}</span>
      </div>
      <span class="text-lg font-590 tracking-tight text-text-primary truncate hidden md:inline">{company.name}</span>
    </div>
    """
  end

  attr :collapsed, :boolean, required: true

  def collapse_toggle(%{collapsed: true}) do
    ~H"""
    <button
      type="button"
      class="hidden lg:block p-1.5 rounded-md text-text-quaternary hover:text-text-primary hover:bg-white/[0.04] transition-colors"
      onclick="window.dispatchEvent(new CustomEvent('expand_rail'))"
    >
      <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 19l-7-7 7-7m8 14l-7-7 7-7"/>
      </svg>
    </button>
    """
  end

  def collapse_toggle(%{collapsed: false}) do
    ~H"""
    <button
      type="button"
      class="hidden lg:block p-1.5 rounded-md text-text-quaternary hover:text-text-primary hover:bg-white/[0.04] transition-colors"
      onclick="window.dispatchEvent(new CustomEvent('collapse_rail'))"
    >
      <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 5l7 7-7 7M5 5l7 7-7 7"/>
      </svg>
    </button>
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
