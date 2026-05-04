defmodule CymphoWeb.LabelController do
  use CymphoWeb, :controller
  alias Cympho.Labels
  alias Cympho.Labels.Label
  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    company_id = conn.assigns.current_company.id
    render(conn, :index, labels: Labels.list_labels_by_company(company_id))
  end

  def create(conn, %{"label" => label_params}) do
    company_id = conn.assigns.current_company.id
    params = Map.put(label_params, "company_id", company_id)

    with {:ok, label} <- Labels.create_label(params) do
      conn
      |> put_status(:created)
      |> render(:show, label: label)
    end
  end

  def update(conn, %{"id" => id, "label" => label_params}) do
    company_id = conn.assigns.current_company.id

    with {:ok, %Label{} = label} <- Labels.get_company_label(company_id, id),
         {:ok, %Label{} = label} <- Labels.update_label(label, label_params) do
      render(conn, :show, label: label)
    end
  end

  def delete(conn, %{"id" => id}) do
    company_id = conn.assigns.current_company.id

    with {:ok, %Label{} = label} <- Labels.get_company_label(company_id, id) do
      {:ok, ^label} = Labels.delete_label(label)
      send_resp(conn, :no_content, "")
    end
  end
end
