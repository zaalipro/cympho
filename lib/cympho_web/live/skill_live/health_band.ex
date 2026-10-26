defmodule CymphoWeb.SkillLive.HealthBand do
  @moduledoc """
  The Advanced health band of the Skills and Plugins pages (v7 H3, H7): the
  level as a status word, the summary, one strip of at most four counts, the
  next action, and the other recommendations as rows. Both read the same map
  (`Cympho.Skills.health_summary/1`, `Cympho.Plugins.health_summary/1`).
  """
  use Phoenix.Component

  import CymphoWeb.Components.R3

  attr :id, :string, required: true, doc: "the band heading's id"
  attr :title, :string, required: true
  attr :health, :map, required: true, doc: "level, label, summary, recommendations, next_action"
  attr :cells, :list, required: true, doc: "[{label, value}], at most four"
  attr :next_path, :string, required: true
  attr :next_testid, :string, required: true
  attr :rest, :global, doc: "data-testid on the band"
  slot :inner_block, doc: "one more quiet line under the strip"

  def health_band(assigns) do
    assigns =
      assign(
        assigns,
        :others,
        Enum.reject(assigns.health.recommendations, &(&1.key == assigns.health.next_action.key))
      )

    ~H"""
    <.band_card id={@id} title={@title} class="ui-advanced-only" {@rest}>
      <:header_end>
        <span class="meta hr-st">
          <.status_word kind={level_kind(@health.level)} word={@health.label} />
        </span>
      </:header_end>
      <p class="gl-sub hb-line">{@health.summary}</p>
      <div class="strip s4">
        <div :for={{label, value} <- @cells} class="cell">
          <span class="v mono">{value}</span><span class="l">{label}</span>
        </div>
      </div>
      <p :if={@inner_block != []} class="gl-sub hb-line">{render_slot(@inner_block)}</p>
      <div class="gl-sec hb-next" data-testid={@next_testid}>
        <h3 class="gl-h">Do this next</h3>
        <p class="gl-big">{@health.next_action.label}</p>
        <p class="gl-sub">{@health.next_action.detail}</p>
        <.text_link navigate={@next_path}>{@health.next_action.cta}</.text_link>
      </div>
      <ul :if={@others != []} class="rows">
        <.list_row
          :for={recommendation <- @others}
          id={"#{@id}-#{recommendation.key}"}
          title={recommendation.label}
          icon="i-alert"
          kind={row_kind(recommendation.severity)}
        >
          <:meta>{recommendation.detail}</:meta>
        </.list_row>
      </ul>
    </.band_card>
    """
  end

  defp level_kind(:critical), do: :stopped
  defp level_kind(:warning), do: :waiting
  defp level_kind(:healthy), do: :done
  defp level_kind(_level), do: :idle

  defp row_kind(:critical), do: :problem
  defp row_kind(:warning), do: :question
  defp row_kind(_severity), do: :neutral
end
