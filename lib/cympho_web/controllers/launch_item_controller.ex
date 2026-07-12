defmodule CymphoWeb.LaunchItemController do
  use CymphoWeb, :controller

  alias Cympho.LaunchItems
  alias Cympho.LaunchItems.LaunchItem

  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    company_id = conn.assigns.current_company.id
    render(conn, :index, launch_items: LaunchItems.list_company_launch_items(company_id))
  end

  def create(conn, %{"launch_item" => launch_item_params}) do
    attrs =
      launch_item_params
      |> Map.put("company_id", conn.assigns.current_company.id)
      |> Map.put_new("owner_user_id", conn.assigns.current_user.id)

    with {:ok, %LaunchItem{} = launch_item} <- LaunchItems.create_launch_item(attrs) do
      conn
      |> put_status(:created)
      |> render(:show, launch_item: launch_item)
    end
  end

  def create(conn, params), do: create(conn, %{"launch_item" => params})

  def show(conn, %{"id" => id}) do
    company_id = conn.assigns.current_company.id

    with {:ok, %LaunchItem{} = launch_item} <- LaunchItems.get_company_launch_item(company_id, id) do
      render(conn, :show, launch_item: launch_item)
    end
  end

  def update(conn, %{"id" => id, "launch_item" => launch_item_params}) do
    company_id = conn.assigns.current_company.id

    with {:ok, %LaunchItem{} = launch_item} <- LaunchItems.get_company_launch_item(company_id, id),
         {:ok, %LaunchItem{} = launch_item} <-
           LaunchItems.update_launch_item(launch_item, launch_item_params) do
      render(conn, :show, launch_item: launch_item)
    end
  end

  def update(conn, %{"id" => id} = params),
    do: update(conn, %{"id" => id, "launch_item" => params})

  def delete(conn, %{"id" => id}) do
    company_id = conn.assigns.current_company.id

    with {:ok, %LaunchItem{} = launch_item} <- LaunchItems.get_company_launch_item(company_id, id),
         {:ok, _launch_item} <- LaunchItems.delete_launch_item(launch_item) do
      send_resp(conn, :no_content, "")
    end
  end
end
