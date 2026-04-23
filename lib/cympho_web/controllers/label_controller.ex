defmodule CymphoWeb.LabelController do
  use CymphoWeb, :controller

  alias Cympho.Labels

  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    labels = Labels.list_labels()
    json(conn, %{data: Enum.map(labels, &CymphoWeb.LabelJSON.label_data/1)})
  end

  def show(conn, %{"id" => id}) do
    case Labels.get_label(id) do
      {:ok, label} ->
        json(conn, %{data: CymphoWeb.LabelJSON.label_data(label)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def create(conn, %{"label" => label_params}) do
    # TODO: Add project ownership/membership authorization check before creating labels.
    # Currently any authenticated user can create labels on any project by passing any project_id.
    # Once user-project membership is implemented, verify the user has access to label_params["project_id"].
    with {:ok, label} <- Labels.create_label(label_params) do
      conn
      |> put_status(:created)
      |> json(%{data: CymphoWeb.LabelJSON.label_data(label)})
    end
  end

  def update(conn, %{"id" => id, "label" => label_params}) do
    with {:ok, label} <- Labels.get_label(id),
         {:ok, label} <- Labels.update_label(label, label_params) do
      json(conn, %{data: CymphoWeb.LabelJSON.label_data(label)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, label} <- Labels.get_label(id),
         {:ok, _label} <- Labels.delete_label(label) do
      send_resp(conn, :no_content, "")
    end
  end
end
