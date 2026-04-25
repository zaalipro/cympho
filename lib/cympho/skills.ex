defmodule Cympho.Skills do
  @moduledoc """
  The Skills context manages company and project-level skills.
  """

  import Ecto.Query
  alias Cympho.{Repo, Skills.Skill}

  def list_skills(opts \\ []) do
    company_id = Keyword.get(opts, :company_id)
    project_id = Keyword.get(opts, :project_id)

    Skill
    |> maybe_filter_by_company(company_id)
    |> maybe_filter_by_project(project_id)
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  def get_skill(id) do
    case Repo.get(Skill, id) do
      nil -> {:error, :not_found}
      skill -> {:ok, Repo.preload(skill, [:company, :project])}
    end
  end

  def get_skill_by_identifier(identifier, company_id) do
    query =
      from s in Skill,
      where: s.identifier == ^identifier and s.company_id == ^company_id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      skill -> {:ok, skill}
    end
  end

  def create_skill(attrs \\ %{}) do
    %Skill{}
    |> Skill.changeset(attrs)
    |> Repo.insert()
  end

  def update_skill(%Skill{} = skill, attrs) do
    skill
    |> Skill.changeset(attrs)
    |> Repo.update()
  end

  def delete_skill(%Skill{} = skill) do
    Repo.delete(skill)
  end

  def toggle_skill(%Skill{} = skill) do
    update_skill(skill, %{enabled: not skill.enabled})
  end

  def update_skill_settings(%Skill{} = skill, settings) do
    update_skill(skill, %{settings: settings})
  end

  defp maybe_filter_by_company(query, nil), do: query
  defp maybe_filter_by_company(query, company_id) do
    from s in query, where: s.company_id == ^company_id
  end

  defp maybe_filter_by_project(query, nil), do: query
  defp maybe_filter_by_project(query, project_id) do
    from s in query, where: s.project_id == ^project_id
  end

  def change_skill(%Skill{} = skill, attrs \\ %{}) do
    Skill.changeset(skill, attrs)
  end
end

