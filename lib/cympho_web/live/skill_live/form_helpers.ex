defmodule CymphoWeb.SkillLive.FormHelpers do
  @moduledoc false

  use CymphoWeb, :html

  alias Cympho.Projects

  @default_entrypoint "Cympho.Skills.CustomSkill"

  attr :form, :any, required: true
  attr :project_options, :list, required: true
  attr :heading, :string, required: true, doc: "\"After you create it\" | \"After you save\""
  attr :submit, :string, required: true, doc: "\"Create skill\" | \"Save skill\""
  attr :cancel, :string, required: true, doc: "where Cancel goes"

  @doc """
  The skill form shared by New and Edit (v7 H4/H6): today's controls and names
  (the manifest is built from Entrypoint and Capabilities, `normalize_skill_params/3`)
  in three field cards beside the ink card.
  """
  def skill_form(assigns) do
    ~H"""
    <.form_pair
      id="skill-form"
      for={@form}
      phx-change="validate"
      phx-submit="save"
      heading={@heading}
      verb="save"
    >
      <.band_card id="sf-skill-t" title="Skill">
        <div class="flds">
          <.input field={@form[:name]} label="Name" required placeholder="Repository Auditor" />
          <.input
            field={@form[:identifier]}
            label="Identifier"
            required
            placeholder="repo_auditor"
            class="mono"
          />
          <.input
            field={@form[:description]}
            label="Usage brief"
            type="textarea"
            rows={5}
            placeholder="What this skill enables, what input it expects, and what evidence it should return."
            wrapper_class="full"
          />
        </div>
      </.band_card>

      <.band_card id="sf-call-t" title="How agents call it">
        <div class="flds">
          <.input
            id="skill-entrypoint"
            name="skill[entrypoint]"
            label="Entrypoint"
            value={manifest_entrypoint(@form[:manifest].value)}
            placeholder="Cympho.Skills.CustomSkill"
            required
            class="mono"
          />
          <.input
            id="skill-capabilities"
            name="skill[capabilities]"
            label="Capabilities"
            value={capabilities_value(@form[:manifest].value)}
            placeholder="repo_audit, test_plan"
            help="Separate them with commas."
          />
        </div>
      </.band_card>

      <.band_card id="sf-scope-t" title="Scope">
        <div class="flds">
          <.input field={@form[:version]} label="Version" placeholder="0.1.0" class="mono" />
          <.input field={@form[:author]} label="Author" placeholder="Cympho Labs" />
          <.input
            type="select"
            field={@form[:project_id]}
            label="Project scope"
            value={@form[:project_id].value || ""}
            options={@project_options}
          />
          <.input
            type="select"
            field={@form[:enabled]}
            label="Availability"
            value={to_string(if is_nil(@form[:enabled].value), do: true, else: @form[:enabled].value)}
            options={[{"Enabled", "true"}, {"Disabled", "false"}]}
          />
        </div>
      </.band_card>

      <:effect>
        <.consequences rows={[{:done, "Agents can use it once it is on."}]} />
      </:effect>
      <:secondary>
        <.ghost_pill navigate={@cancel}>Cancel</.ghost_pill>
      </:secondary>
      <:primary>
        <.primary_pill type="submit" phx-disable-with="Saving…">{@submit}</.primary_pill>
      </:primary>
    </.form_pair>
    """
  end

  def assign_context_options(socket) do
    company_id = current_company_id(socket)

    assign(socket, :project_options, project_options(company_id))
  end

  def normalize_skill_params(socket, params, opts \\ []) do
    company_id = current_company_id(socket)

    with :ok <- validate_project_ref(company_id, params["project_id"]) do
      base_manifest = opts |> Keyword.get(:skill) |> existing_manifest()

      # company_id is server-owned: drop any client value, then re-add the socket's.
      params =
        params
        |> Map.drop(["entrypoint", "capabilities", "company_id"])
        |> maybe_put_company_scope(company_id, Keyword.get(opts, :put_company_scope))
        |> Map.put("manifest", build_manifest(base_manifest, params))

      {:ok, params}
    end
  end

  def manifest_entrypoint(%{manifest: manifest}), do: manifest_entrypoint(manifest)

  def manifest_entrypoint(manifest) when is_map(manifest) do
    Map.get(manifest, "entrypoint") || Map.get(manifest, :entrypoint) || @default_entrypoint
  end

  def manifest_entrypoint(_manifest), do: @default_entrypoint

  def capabilities_value(%{manifest: manifest}), do: capabilities_value(manifest)

  def capabilities_value(manifest) when is_map(manifest) do
    capabilities =
      Map.get(manifest, "capabilities") || Map.get(manifest, :capabilities) || []

    if is_list(capabilities), do: Enum.join(capabilities, ", "), else: ""
  end

  def capabilities_value(_manifest), do: ""

  defp build_manifest(base_manifest, params) do
    base_manifest
    |> Map.put("name", fallback(params["name"], "Untitled Skill"))
    |> Map.put("version", fallback(params["version"], "0.1.0"))
    |> Map.put("author", fallback(params["author"], "Cympho Labs"))
    |> Map.put("entrypoint", fallback(params["entrypoint"], @default_entrypoint))
    |> Map.put("capabilities", split_capabilities(params["capabilities"]))
    |> Map.put_new("dependencies", %{})
    |> Map.put_new("permissions", [])
  end

  defp existing_manifest(%{manifest: manifest}) when is_map(manifest),
    do: stringify_keys(manifest)

  defp existing_manifest(_skill), do: %{}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp split_capabilities(nil), do: []

  defp split_capabilities(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_capabilities(value) when is_list(value), do: value
  defp split_capabilities(_value), do: []

  defp fallback(value, default) when value in [nil, ""], do: default
  defp fallback(value, _default), do: value

  defp project_options(nil), do: [{"Company-wide skill", ""}]

  defp project_options(company_id) do
    options =
      company_id
      |> Projects.list_projects_by_company()
      |> Enum.reject(&(&1.status == :archived))
      |> Enum.map(&{&1.name, &1.id})

    [{"Company-wide skill", ""} | options]
  end

  defp validate_project_ref(_company_id, nil), do: :ok
  defp validate_project_ref(_company_id, ""), do: :ok

  defp validate_project_ref(company_id, project_id) when is_binary(company_id) do
    case Projects.get_company_project(company_id, project_id) do
      {:ok, _project} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  defp validate_project_ref(_company_id, _project_id), do: {:error, :not_found}

  defp maybe_put_company_scope(params, nil, _put_scope?), do: params
  defp maybe_put_company_scope(params, _company_id, false), do: params

  defp maybe_put_company_scope(params, company_id, _put_scope?),
    do: Map.put_new(params, "company_id", company_id)

  defp current_company_id(%{assigns: %{current_company: %{id: id}}}), do: id
  defp current_company_id(_socket), do: nil
end
