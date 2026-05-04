defmodule Cympho.Labels do
  @moduledoc "Labels context."

  import Ecto.Query, warn: false

  alias Cympho.Repo
  alias Cympho.Labels.Label

  def list_labels do
    Label
    |> order_by([l], asc: l.name)
    |> Repo.all()
  end

  def list_labels_by_company(company_id) do
    Label
    |> where(company_id: ^company_id)
    |> order_by([l], asc: l.name)
    |> Repo.all()
  end

  def get_label!(id), do: Repo.get!(Label, id)

  def get_label(id) do
    case Repo.get(Label, id) do
      nil -> {:error, :not_found}
      label -> {:ok, label}
    end
  end

  def get_company_label(company_id, id) do
    case Repo.one(from l in Label, where: l.id == ^id and l.company_id == ^company_id) do
      nil -> {:error, :not_found}
      label -> {:ok, label}
    end
  end

  def change_label(%Label{} = label, attrs \\ %{}) do
    Label.changeset(label, attrs)
  end

  def update_label(%Label{} = label, attrs) do
    label
    |> Label.changeset(attrs)
    |> Repo.update()
  end

  def create_label(attrs) do
    %Label{}
    |> Label.changeset(attrs)
    |> Repo.insert()
  end

  def delete_label(%Label{} = label) do
    Repo.delete(label)
  end
end
