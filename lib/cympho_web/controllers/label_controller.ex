defmodule CymphoWeb.LabelController do
  use CymphoWeb, :controller
  alias Cympho.Labels
  alias Cympho.Labels.Label
  action_fallback CymphoWeb.FallbackController

  def index(conn, _params), do: render(conn, :index, labels: Labels.list_labels())

  def create(conn, %{"label" => label_params}) do
    # TODO: Add project ownership/membership authorization check before creating labels.
    # Currently any authenticated user can create labels on any project by passing any project_id.
    # Once user-project membership is implemented, verify the user has access to label_params["project_id"].
    with {:ok, label} <- Labels.create_label(label_params) do
      conn
      |> put_status(:created)
      |> render(:show, label: label)
    end
  end

  def update(conn, %{"id" => id, "label" => label_params}) do
    with {:ok, %Label{} = label} <- Labels.get_label(id),
         {:ok, %Label{} = label} <- Labels.update_label(label, label_params) do
      render(conn, :show, label: label)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %Label{} = label} <- Labels.get_label(id) do
      {:ok, ^label} = Labels.delete_label(label)
      send_resp(conn, :no_content, "")
    end
  end
end
