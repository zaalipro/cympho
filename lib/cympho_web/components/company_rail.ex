defmodule CymphoWeb.Components.CompanyRail do
  @moduledoc """
  The rail's company switch (r3 `details.switch`) and the phone top bar's
  company tile.

  The power line shows the company state only: Paused, Low power or Full
  power. Whether this server runs agents at all (the dispatcher) is the first
  line of the switch's menu, so the closed switch matches the mockups while
  the owner can still find out why nothing runs.
  """
  use Phoenix.Component

  import CymphoWeb.Components.R3, only: [r3_icon: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: CymphoWeb.Endpoint,
    router: CymphoWeb.Router

  attr :company, :map, default: nil
  attr :current_path, :string, default: "/"
  attr :runtime_controls_allowed, :boolean, default: false
  attr :dispatcher_on, :boolean, required: true

  def company_switch(assigns) do
    ~H"""
    <details class="switch">
      <summary data-testid="runtime-status-trigger" title={"Runtime: #{power_word(@company)}"}>
        <span class="tile-co" aria-hidden="true">{company_initials(@company)}</span>
        <span class="co-txt">
          <span class="co-name">{company_name(@company)}</span>
          <span :if={@company} class="co-power">
            <span class="pw-dot" data-power={power_key(@company)} aria-hidden="true"></span>{power_word(
              @company
            )}
          </span>
        </span>
        <.r3_icon name="i-chev-updown" />
      </summary>
      <div class="menu">
        <p :if={!@dispatcher_on} class="menu-note">Agents are switched off on this server</p>
        <.runtime_control_menu
          :if={@runtime_controls_allowed && @company}
          company={@company}
          current_path={@current_path}
        />
        <button type="button" data-company-rail-switcher data-runtime-menu-close>
          Switch company
        </button>
        <a href={~p"/companies"}>Manage companies</a>
      </div>
    </details>
    """
  end

  attr :company, :map, required: true
  attr :current_path, :string, required: true

  # The company's power actions: the existing runtime-control POST forms.
  def runtime_control_menu(assigns) do
    ~H"""
    <div class="menu-runtime" data-testid="runtime-controls">
      <.runtime_button
        :if={!company_paused?(@company) && !company_low_power?(@company)}
        action={~p"/runtime-control/low-power"}
        label="Low power"
        detail="Only High and Critical tasks run."
        current_path={@current_path}
        confirm="Switch to low power? Only urgent work keeps running."
      />
      <.runtime_button
        :if={!company_paused?(@company) && company_low_power?(@company)}
        action={~p"/runtime-control/resume"}
        label="Full power"
        current_path={@current_path}
      />
      <.runtime_button
        :if={!company_paused?(@company)}
        action={~p"/runtime-control/pause"}
        label="Pause company"
        detail="Queued work is saved for later."
        current_path={@current_path}
        confirm="Pause your agents? Queued work is saved for later."
      />
      <.runtime_button
        :if={company_paused?(@company)}
        action={~p"/runtime-control/resume"}
        label="Resume agents"
        detail="Agents start picking up work again."
        current_path={@current_path}
      />
      <.runtime_button
        action={~p"/runtime-control/stop"}
        label="Stop company"
        detail="Agents stop and the queue is cleared."
        current_path={@current_path}
        confirm="Stop your agents and clear the queue?"
      />
    </div>
    """
  end

  attr :action, :string, required: true
  attr :label, :string, required: true
  attr :detail, :string, default: nil
  attr :current_path, :string, required: true
  attr :confirm, :string, default: nil

  defp runtime_button(assigns) do
    ~H"""
    <form method="post" action={@action}>
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <input type="hidden" name="return_to" value={@current_path} />
      <button type="submit" data-confirm={@confirm}>
        {@label}<small :if={@detail}>{@detail}</small>
      </button>
    </form>
    """
  end

  attr :company, :map, default: nil

  @doc "The phone top bar's company tile: opens the company switcher."
  def company_tile(assigns) do
    ~H"""
    <button type="button" class="tb-co" data-company-rail-switcher>
      <span class="tile-co" aria-hidden="true">{company_initials(@company)}</span>
      <span :if={@company} class="pw-dot" data-power={power_key(@company)} aria-hidden="true"></span>
      <span class="sr">{tile_label(@company)}</span>
      <.r3_icon name="i-chev-updown" />
    </button>
    """
  end

  defp tile_label(nil), do: "Cympho, switch company"
  defp tile_label(company), do: "#{company.name}, #{power_word(company)}"

  defp company_name(nil), do: "Cympho"
  defp company_name(%{name: name}), do: name

  # The brand tile reads the company's task prefix ("NW"), else its initials.
  defp company_initials(%{issue_prefix: prefix}) when is_binary(prefix) and prefix != "",
    do: prefix |> String.slice(0, 3) |> String.upcase()

  defp company_initials(%{name: name}) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp company_initials(_), do: "Cy"

  defp company_paused?(%{status: "paused"}), do: true
  defp company_paused?(_company), do: false

  defp company_low_power?(%{governance_config: %{"runtime_mode" => "low_power"}}), do: true
  defp company_low_power?(_company), do: false

  defp power_key(company) do
    cond do
      company_paused?(company) -> "paused"
      company_low_power?(company) -> "low"
      true -> "full"
    end
  end

  defp power_word(company) do
    case power_key(company) do
      "paused" -> "Paused"
      "low" -> "Low power"
      "full" -> "Full power"
    end
  end
end
