defmodule Cympho.Labels do
  @moduledoc """
  Labels context.

  Request paths use `list_company_labels_page/2`, `list_labels_by_company/1`,
  and `get_company_label/2`. `list_labels/0` and `list_labels_page/1` stay
  unscoped. The unique index remains on `name` alone.
  """

  import Ecto.Query, warn: false

  alias Cympho.Repo
  alias Cympho.Labels.Label

  def list_labels do
    Label
    |> order_by([l], asc: l.name)
    |> Repo.all()
  end

  @doc """
  Keyset (infinite-scroll) page of all labels, ordered by name ascending.
  """
  def list_labels_page(opts \\ []) do
    Label
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:name, :asc}, {:id, :asc}]
    )
  end

  @doc """
  Keyset (infinite-scroll) page of one company's labels, ordered by name ascending.
  """
  def list_company_labels_page(company_id, opts \\ []) do
    Label
    |> where(company_id: ^company_id)
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:name, :asc}, {:id, :asc}]
    )
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
