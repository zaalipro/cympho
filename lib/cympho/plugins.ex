defmodule Cympho.Plugins do
  @moduledoc """
  The Plugins context manages company and project-level plugins.
  """

  import Ecto.Query
  alias Cympho.{Repo, Plugins.Plugin}

  def list_plugins(opts \\ []) do
    company_id = Keyword.get(opts, :company_id)
    project_id = Keyword.get(opts, :project_id)
    status = Keyword.get(opts, :status)

    Plugin
    |> maybe_filter_by_company(company_id)
    |> maybe_filter_by_project(project_id)
    |> maybe_filter_by_status(status)
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  def get_plugin(id) do
    case Repo.get(Plugin, id) do
      nil -> {:error, :not_found}
      plugin -> {:ok, Repo.preload(plugin, [:company, :project])}
    end
  end

  def get_company_plugin(company_id, id) do
    query = from p in Plugin, where: p.id == ^id and p.company_id == ^company_id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      plugin -> {:ok, Repo.preload(plugin, [:company, :project])}
    end
  end

  def get_plugin_by_identifier(identifier, company_id) do
    query =
      from p in Plugin,
        where: p.identifier == ^identifier and p.company_id == ^company_id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      plugin -> {:ok, plugin}
    end
  end

  def create_plugin(attrs \\ %{}) do
    %Plugin{}
    |> Plugin.changeset(attrs)
    |> Repo.insert()
  end

  def update_plugin(%Plugin{} = plugin, attrs) do
    plugin
    |> Plugin.changeset(attrs)
    |> Repo.update()
  end

  def delete_plugin(%Plugin{} = plugin) do
    Repo.delete(plugin)
  end

  def toggle_plugin(%Plugin{} = plugin) do
    new_enabled = not plugin.enabled
    new_status = if new_enabled, do: "active", else: "disabled"

    update_plugin(plugin, %{enabled: new_enabled, status: new_status})
  end

  def update_plugin_settings(%Plugin{} = plugin, settings) do
    current_settings = plugin.settings || %{}
    updated_settings = Map.merge(current_settings, settings)

    update_plugin(plugin, %{settings: updated_settings})
  end

  def change_plugin(%Plugin{} = plugin, attrs \\ %{}) do
    Plugin.changeset(plugin, attrs)
  end

  defp maybe_filter_by_company(query, nil), do: query

  defp maybe_filter_by_company(query, company_id) do
    from p in query, where: p.company_id == ^company_id
  end

  defp maybe_filter_by_project(query, nil), do: query

  defp maybe_filter_by_project(query, project_id) do
    from p in query, where: p.project_id == ^project_id
  end

  defp maybe_filter_by_status(query, nil), do: query

  defp maybe_filter_by_status(query, status) do
    from p in query, where: p.status == ^status
  end
end
