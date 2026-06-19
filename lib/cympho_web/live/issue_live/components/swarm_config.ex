defmodule CymphoWeb.IssueLive.Components.SwarmConfig do
  @moduledoc """
  Shared form controls for configuring issue swarm composition.
  """
  use CymphoWeb, :html

  alias Cympho.Adapters.RuntimeOptions
  alias Cympho.Agents.Agent

  @model_suggestions [
    {"Runtime default", ""},
    {"Sonnet", "sonnet"},
    {"Opus", "opus"},
    {"GPT-5.5", "gpt-5.5"},
    {"GPT-5.4 mini", "gpt-5.4-mini"},
    {"GPT-5.3 high fast", "gpt-5.3-high-fast"},
    {"Qwen 3.6 Flash", "qwen3.6-flash"},
    {"Qwen 3.7 Plus", "qwen3.7-plus"},
    {"Auto", "auto"}
  ]

  @doc """
  Default composition rows used by issue creation forms.
  """
  def default_mix_rows do
    %{
      "0" => %{
        "enabled" => "true",
        "harness" => "claude_code",
        "model" => "sonnet",
        "reasoning_effort" => "medium"
      }
    }
  end

  attr :id, :string, required: true
  attr :title, :string, default: "Swarm composition"
  attr :description, :string, default: nil
  attr :swarm_params, :map, default: %{}
  attr :swarm_config, :map, default: nil
  attr :proxy_profiles, :list, default: []
  attr :compact, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def swarm_configuration(assigns) do
    params = normalize_params(assigns.swarm_params)
    rows = swarm_mix_rows(params)

    assigns =
      assigns
      |> assign(:swarm_params, params)
      |> assign(:rows, rows)
      |> assign(:choice_count, length(rows))
      |> assign(:next_index, next_mix_index(rows))
      |> assign(:harness_options, harness_options())
      |> assign(:reasoning_options, reasoning_options())
      |> assign(:model_suggestions, @model_suggestions)
      |> assign(:proxy_pool_slots, proxy_pool_slots(params["proxy_pool"]))
      |> assign(:summary_labels, summary_labels(assigns.swarm_config, rows))
      |> assign(:proxy_label, proxy_label(assigns.swarm_config, params))

    ~H"""
    <section
      id={@id}
      data-testid={@id}
      class={[
        "rounded-lg border border-cyan-500/20 bg-canvas/70",
        @compact && "space-y-3 p-3",
        !@compact && "space-y-4 p-4",
        @class
      ]}
      {@rest}
    >
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <span class="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-md border border-cyan-500/20 bg-cyan-500/10 text-cyan-200">
              <.icon name="hero-squares-2x2-mini" class="h-4 w-4" />
            </span>
            <p class="text-xs font-590 uppercase tracking-[0.08em] text-cyan-200">
              {@title}
            </p>
          </div>
          <p class="mt-2 max-w-2xl text-xs leading-5 text-text-tertiary">
            {@description ||
              "Choose the runtime mix by cost and capability. CTO and CEO assign the worker lenses automatically."}
          </p>
        </div>

        <a
          href={~p"/settings/proxies"}
          class="inline-flex shrink-0 items-center justify-center gap-1.5 rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-text-secondary hover:bg-surface-hover hover:text-text-primary"
        >
          <.icon name="hero-globe-alt-mini" class="h-3.5 w-3.5" /> Manage proxies
        </a>
      </div>

      <div class={[
        "grid gap-3",
        @compact && "lg:grid-cols-[120px_minmax(0,1fr)]",
        !@compact && "lg:grid-cols-[160px_minmax(0,1fr)]"
      ]}>
        <label class="block">
          <span class="text-xs font-590 text-text-secondary">Temporary agents</span>
          <input
            type="number"
            name="swarm[agent_count]"
            min="1"
            max="12"
            value={@swarm_params["agent_count"]}
            class="mt-1 block h-9 w-full rounded-md border border-border bg-canvas px-3 text-sm text-text-primary focus:border-brand focus:ring-brand/30"
          />
        </label>

        <div class="rounded-md border border-border bg-panel/70 px-3 py-2">
          <div class="flex flex-wrap items-center gap-2">
            <span class="rounded-full border border-cyan-500/20 bg-cyan-500/10 px-2 py-0.5 text-[10px] font-590 uppercase tracking-[0.06em] text-cyan-100">
              <span data-swarm-count>{@choice_count}</span> {runtime_choice_label(@choice_count)}
            </span>
            <span class="rounded-full border border-border bg-canvas px-2 py-0.5 text-[10px] text-text-tertiary">
              Random choice per worker
            </span>
            <span class="rounded-full border border-border bg-canvas px-2 py-0.5 text-[10px] text-text-tertiary">
              CTO synthesis
            </span>
            <span class="rounded-full border border-border bg-canvas px-2 py-0.5 text-[10px] text-text-tertiary">
              CEO handoff
            </span>
          </div>
          <p class="mt-2 text-[11px] leading-4 text-text-tertiary">
            Starts with a local/reviewable runtime. Add paid providers only after their credentials are configured.
          </p>
        </div>
      </div>

      <div
        id={"#{@id}-composition"}
        data-swarm-composition
        data-swarm-next-index={@next_index}
        phx-update="ignore"
        class="rounded-md border border-border bg-panel/70 px-3 py-3"
      >
        <input
          type="hidden"
          name="swarm[composition_changed]"
          value="0"
          data-swarm-change-marker
        />

        <div class="-mx-1 overflow-x-auto px-1">
          <div class="grid min-w-[640px] grid-cols-[minmax(180px,1.15fr)_minmax(180px,1fr)_120px_72px] gap-2">
            <.field_select
              id={"#{@id}-choice-harness"}
              label="Harness"
              value="claude_code"
              options={@harness_options}
              data-swarm-choice-harness="true"
            />
            <.model_input
              id={"#{@id}-choice-model"}
              value=""
              suggestions={@model_suggestions}
              data-swarm-choice-model="true"
            />
            <.field_select
              id={"#{@id}-choice-reasoning"}
              label="Effort"
              value="auto"
              options={@reasoning_options}
              data-swarm-choice-reasoning="true"
            />
            <div class="flex items-end">
              <button
                type="button"
                data-swarm-add-row
                class="inline-flex h-9 w-full items-center justify-center gap-1.5 rounded-md border border-cyan-500/25 bg-cyan-500/10 px-3 text-xs font-590 text-cyan-100 hover:bg-cyan-500/15"
              >
                <.icon name="hero-plus-mini" class="h-4 w-4" /> Add
              </button>
            </div>
          </div>
        </div>

        <div class="mt-3 overflow-x-auto rounded-md border border-border bg-canvas">
          <table class="min-w-[640px] w-full divide-y divide-border text-left text-xs">
            <thead class="bg-panel/60 text-[10px] font-590 uppercase tracking-[0.08em] text-text-quaternary">
              <tr>
                <th class="min-w-[180px] px-3 py-2">Harness</th>
                <th class="min-w-[180px] px-3 py-2">Model</th>
                <th class="w-[120px] min-w-[120px] px-3 py-2">Effort</th>
                <th class="w-28 min-w-[7rem] px-2 py-2"></th>
              </tr>
            </thead>
            <tbody data-swarm-rows class="divide-y divide-border">
              <.swarm_choice_row :for={row <- @rows} id={@id} row={row} />
              <tr data-swarm-empty-row class={[@choice_count > 0 && "hidden"]}>
                <td colspan="4" class="px-3 py-3 text-text-tertiary">
                  Add at least one runtime choice, or leave the defaults to use the platform runtime.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div :if={!@compact} class="space-y-4">
        <div class="grid gap-4 xl:grid-cols-[220px_minmax(0,1fr)]">
          <.field_select
            id={"#{@id}-proxy-mode"}
            name="swarm[proxy_mode]"
            label="Proxy selection"
            value={@swarm_params["proxy_mode"]}
            options={proxy_mode_options()}
          />

          <div class="rounded-md border border-border bg-panel/70 px-3 py-3">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <p class="text-xs font-590 text-text-secondary">Saved proxies</p>
                <p class="mt-0.5 text-[11px] leading-4 text-text-tertiary">
                  Random uses every saved proxy. Selected uses only checked profiles.
                </p>
              </div>
              <span class="text-[11px] text-text-quaternary">{length(@proxy_profiles)} saved</span>
            </div>

            <div :if={@proxy_profiles == []} class="mt-3 text-xs text-text-tertiary">
              No saved proxies yet. Add profiles in Settings, or use named profile slots below.
            </div>

            <div :if={@proxy_profiles != []} class="mt-3 grid gap-2 sm:grid-cols-2">
              <label
                :for={proxy <- @proxy_profiles}
                class="flex min-w-0 cursor-pointer items-start gap-2 rounded-md border border-border bg-canvas px-2.5 py-2"
              >
                <input
                  type="checkbox"
                  name="swarm[proxy_profile_ids][]"
                  value={proxy.id}
                  checked={proxy.id in @swarm_params["proxy_profile_ids"]}
                  class="mt-0.5 h-4 w-4 rounded border-border bg-canvas text-brand focus:ring-brand/40"
                />
                <span class="min-w-0">
                  <span class="block truncate text-xs font-590 text-text-primary">{proxy.name}</span>
                  <span class="mt-0.5 block truncate font-mono text-[11px] text-text-tertiary">
                    {proxy.proxy_type}://{proxy.host}:{proxy.port}
                  </span>
                </span>
              </label>
            </div>
          </div>
        </div>

        <div class="rounded-md border border-border bg-panel/70 px-3 py-3">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p class="text-xs font-590 text-text-secondary">Named proxy slots</p>
              <p class="mt-0.5 text-[11px] leading-4 text-text-tertiary">
                Optional managed profile references. Use saved profile names only; raw URLs are ignored by the launcher.
              </p>
            </div>
            <span class="text-[11px] text-text-quaternary">Manual mode</span>
          </div>
          <div class="mt-3 grid gap-2 sm:grid-cols-3">
            <label :for={{value, index} <- Enum.with_index(@proxy_pool_slots, 1)} class="block">
              <span class="mb-1 block text-[10px] font-590 uppercase tracking-[0.08em] text-text-quaternary">
                Profile {index}
              </span>
              <input
                type="text"
                name="swarm[proxy_pool][]"
                value={value}
                placeholder="managed-egress"
                class="block h-9 w-full rounded-md border border-border bg-canvas px-2.5 text-xs text-text-primary placeholder:text-text-quaternary focus:border-brand focus:ring-brand/30"
              />
            </label>
          </div>
        </div>

        <div class="grid gap-2 sm:grid-cols-3">
          <div
            :for={label <- @summary_labels}
            class="rounded-md border border-border bg-panel/70 px-3 py-2 text-xs leading-5 text-text-secondary"
          >
            {label}
          </div>
          <div class="rounded-md border border-border bg-panel/70 px-3 py-2 text-xs leading-5 text-text-tertiary">
            {@proxy_label}
          </div>
        </div>
      </div>

      <details
        :if={@compact}
        class="rounded-md border border-border bg-panel/70 px-3 py-2 text-xs text-text-secondary"
      >
        <summary class="flex cursor-pointer list-none items-center justify-between gap-3">
          <span class="font-590">Proxy routing</span>
          <span class="text-text-quaternary">{@proxy_label}</span>
        </summary>
        <div class="mt-3">
          <.field_select
            id={"#{@id}-proxy-mode"}
            name="swarm[proxy_mode]"
            label="Proxy selection"
            value={@swarm_params["proxy_mode"]}
            options={proxy_mode_options()}
          />
          <div :if={@proxy_profiles != []} class="mt-3 grid gap-2 sm:grid-cols-2">
            <label
              :for={proxy <- @proxy_profiles}
              class="flex min-w-0 cursor-pointer items-start gap-2 rounded-md border border-border bg-canvas px-2.5 py-2"
            >
              <input
                type="checkbox"
                name="swarm[proxy_profile_ids][]"
                value={proxy.id}
                checked={proxy.id in @swarm_params["proxy_profile_ids"]}
                class="mt-0.5 h-4 w-4 rounded border-border bg-canvas text-brand focus:ring-brand/40"
              />
              <span class="min-w-0">
                <span class="block truncate text-xs font-590 text-text-primary">{proxy.name}</span>
                <span class="mt-0.5 block truncate font-mono text-[11px] text-text-tertiary">
                  {proxy.proxy_type}://{proxy.host}:{proxy.port}
                </span>
              </span>
            </label>
          </div>
          <div class="mt-3 grid gap-2 sm:grid-cols-3">
            <label :for={{value, index} <- Enum.with_index(@proxy_pool_slots, 1)} class="block">
              <span class="mb-1 block text-[10px] font-590 uppercase tracking-[0.08em] text-text-quaternary">
                Profile {index}
              </span>
              <input
                type="text"
                name="swarm[proxy_pool][]"
                value={value}
                placeholder="managed-egress"
                class="block h-9 w-full rounded-md border border-border bg-canvas px-2.5 text-xs text-text-primary placeholder:text-text-quaternary focus:border-brand focus:ring-brand/30"
              />
            </label>
          </div>
        </div>
      </details>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true

  defp swarm_choice_row(assigns) do
    assigns =
      assigns
      |> assign(:index, assigns.row["index"])
      |> assign(:harness_label, harness_label(assigns.row["harness"]))
      |> assign(:model_label, blank_to_default(assigns.row["model"], "Runtime default"))
      |> assign(:reasoning_label, reasoning_label(assigns.row["reasoning_effort"]))

    ~H"""
    <tr
      data-swarm-choice-row
      data-swarm-editable-row
      tabindex="0"
      class="cursor-pointer transition hover:bg-surface-hover/50 focus:outline-none focus:ring-1 focus:ring-cyan-500/40"
    >
      <td class="min-w-[180px] px-3 py-2 align-middle font-510 text-text-primary">
        <input type="hidden" name={"swarm[mix_rows][#{@index}][enabled]"} value="true" />
        <input
          type="hidden"
          name={"swarm[mix_rows][#{@index}][harness]"}
          value={@row["harness"]}
          data-swarm-row-harness-input="true"
        />
        <span data-swarm-row-harness-label>{@harness_label}</span>
      </td>
      <td class="min-w-[180px] px-3 py-2 align-middle font-mono text-text-secondary">
        <input
          type="hidden"
          name={"swarm[mix_rows][#{@index}][model]"}
          value={@row["model"]}
          data-swarm-row-model-input="true"
        />
        <span data-swarm-row-model-label>{@model_label}</span>
      </td>
      <td class="w-[120px] min-w-[120px] px-3 py-2 align-middle text-text-secondary">
        <input
          type="hidden"
          name={"swarm[mix_rows][#{@index}][reasoning_effort]"}
          value={@row["reasoning_effort"]}
          data-swarm-row-reasoning-input="true"
        />
        <span data-swarm-row-reasoning-label>{@reasoning_label}</span>
      </td>
      <td class="w-28 min-w-[7rem] whitespace-nowrap px-2 py-2 text-right align-middle">
        <div
          class="flex h-7 items-center justify-end gap-1 whitespace-nowrap"
          data-swarm-row-actions="true"
        >
          <button
            type="button"
            data-swarm-edit-row
            class="inline-flex h-7 w-7 items-center justify-center rounded-md text-text-tertiary hover:bg-surface-hover hover:text-text-primary"
            aria-label="Edit swarm runtime choice"
          >
            <.icon name="hero-pencil-square-mini" class="h-4 w-4" />
          </button>
          <button
            type="button"
            data-swarm-remove-row
            class="inline-flex h-7 w-7 items-center justify-center rounded-md text-text-tertiary hover:bg-surface-hover hover:text-text-primary"
            aria-label="Remove swarm runtime choice"
          >
            <.icon name="hero-x-mark-mini" class="h-4 w-4" />
          </button>
        </div>
      </td>
    </tr>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, default: nil
  attr :label, :string, required: true
  attr :value, :string, default: ""
  attr :options, :list, required: true
  attr :rest, :global

  defp field_select(assigns) do
    ~H"""
    <label class="block">
      <span class="mb-1 block text-[10px] font-590 uppercase tracking-[0.08em] text-text-quaternary">
        {@label}
      </span>
      <select
        id={@id}
        name={@name}
        class="block h-9 w-full rounded-md border border-border bg-canvas px-2.5 text-xs text-text-primary focus:border-brand focus:ring-brand/30"
        {@rest}
      >
        <option :for={{label, value} <- @options} value={value} selected={@value == value}>
          {label}
        </option>
      </select>
    </label>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, default: nil
  attr :value, :string, default: ""
  attr :suggestions, :list, required: true
  attr :rest, :global

  defp model_input(assigns) do
    ~H"""
    <label class="block">
      <span class="mb-1 block text-[10px] font-590 uppercase tracking-[0.08em] text-text-quaternary">
        Model
      </span>
      <input
        id={@id}
        list={"#{@id}-suggestions"}
        name={@name}
        value={@value}
        placeholder="runtime default or provider model"
        class="block h-9 w-full rounded-md border border-border bg-canvas px-2.5 font-mono text-xs text-text-primary placeholder:font-sans placeholder:text-text-quaternary focus:border-brand focus:ring-brand/30"
        {@rest}
      />
      <datalist id={"#{@id}-suggestions"}>
        <option :for={{label, value} <- @suggestions} value={value}>{label}</option>
      </datalist>
    </label>
    """
  end

  defp normalize_params(params) when is_map(params) do
    %{
      "agent_count" => "3",
      "mix_rows" => default_mix_rows(),
      "proxy_mode" => "none",
      "proxy_profile_ids" => [],
      "proxy_pool" => []
    }
    |> Map.merge(params)
    |> Map.update!("mix_rows", fn
      rows when is_map(rows) -> rows
      _ -> default_mix_rows()
    end)
    |> Map.update!("proxy_profile_ids", &normalize_string_list/1)
  end

  defp normalize_params(_), do: normalize_params(%{})

  defp swarm_mix_rows(%{"mix_rows" => rows}) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _row} -> parse_int(index, 999) end)
    |> Enum.map(fn {index, row} ->
      row = normalize_row(row)
      Map.put(row, "index", to_string(index))
    end)
    |> Enum.filter(&(&1["enabled"] == "true"))
  end

  defp normalize_row(row) when is_map(row) do
    %{
      "enabled" => if(row["enabled"] in ["true", "on", "1", true], do: "true", else: "false"),
      "harness" => row["harness"] || "claude_code",
      "model" => row["model"] || "",
      "reasoning_effort" => normalize_reasoning(row["reasoning_effort"])
    }
  end

  defp normalize_row(_), do: normalize_row(%{})

  defp proxy_pool_slots(value) do
    value
    |> normalize_string_list()
    |> Enum.take(3)
    |> pad_slots(3)
  end

  defp pad_slots(values, count) do
    values ++ List.duplicate("", max(count - length(values), 0))
  end

  defp harness_options do
    adapter_options =
      Agent.adapter_options()
      |> Enum.reject(&(&1 in [:http, :agrenting]))
      |> Enum.map(fn adapter ->
        {adapter |> to_string() |> String.replace("_", " ") |> String.capitalize(),
         to_string(adapter)}
      end)

    process_presets =
      RuntimeOptions.process_preset_options()
      |> Enum.reject(fn {_label, value} -> value == "custom" end)
      |> Enum.map(fn {label, value} -> {"Process: #{label}", "process:#{value}"} end)

    adapter_options ++ process_presets
  end

  defp reasoning_options do
    [
      {"Auto", "auto"},
      {"Low", "low"},
      {"Medium", "medium"},
      {"High", "high"}
    ]
  end

  defp runtime_choice_label(1), do: "runtime choice"
  defp runtime_choice_label(_count), do: "runtime choices"

  defp proxy_mode_options do
    [
      {"No proxies", "none"},
      {"Random from saved", "random"},
      {"Selected saved proxies", "selected"},
      {"Named profile slots", "manual"}
    ]
  end

  defp summary_labels(%{mix: mix}, _rows) when is_list(mix) do
    Enum.map(mix, fn spec ->
      model = spec.model || "default"
      reasoning = spec.reasoning_effort || "auto"

      "#{harness_label(spec)} / #{model} / #{reasoning}"
    end)
  end

  defp summary_labels(_swarm_config, rows) do
    Enum.map(rows, fn row ->
      model = blank_to_default(row["model"], "default")
      reasoning = blank_to_default(row["reasoning_effort"], "auto")

      "#{harness_label(row["harness"])} / #{model} / #{reasoning}"
    end)
  end

  defp proxy_label(%{proxy: %{enabled: true, pool: pool}}, _params)
       when is_list(pool) and length(pool) > 1,
       do: "#{length(pool)} proxy profiles"

  defp proxy_label(%{proxy: %{enabled: true, profile: profile}}, _params), do: profile

  defp proxy_label(_swarm_config, %{"proxy_mode" => "none"}), do: "No proxy profile"
  defp proxy_label(_swarm_config, %{"proxy_mode" => mode}), do: "#{mode} proxy mode"
  defp proxy_label(_swarm_config, _params), do: "No proxy profile"

  defp normalize_reasoning(value) when value in ["auto", "low", "medium", "high"], do: value
  defp normalize_reasoning(_), do: "auto"

  defp next_mix_index(rows) do
    rows
    |> Enum.map(&parse_int(&1["index"], -1))
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  defp harness_label(%{adapter: :process, process_preset: preset}) when is_binary(preset),
    do: harness_label("process:#{preset}")

  defp harness_label(%{adapter: adapter}) when not is_nil(adapter),
    do: harness_label(to_string(adapter))

  defp harness_label(%{"harness" => harness}), do: harness_label(harness)

  defp harness_label(value) do
    value = to_string(value || "")

    harness_options()
    |> Enum.find_value(value, fn {label, option_value} ->
      if option_value == value, do: label
    end)
  end

  defp reasoning_label(value) do
    value = normalize_reasoning(value)

    reasoning_options()
    |> Enum.find_value(String.capitalize(value), fn {label, option_value} ->
      if option_value == value, do: label
    end)
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_string_list(value) when is_binary(value) and value != "" do
    value
    |> String.split(~r/[\n,]+/)
    |> normalize_string_list()
  end

  defp normalize_string_list(_), do: []

  defp blank_to_default(value, default) when value in [nil, ""], do: default
  defp blank_to_default(value, _default), do: value

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_int(_value, default), do: default
end
