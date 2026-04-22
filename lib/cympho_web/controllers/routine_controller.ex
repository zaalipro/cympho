defmodule CymphoWeb.RoutineController do
  use CymphoWeb, :controller

  alias Cympho.Routines
  alias Cympho.Routines.Routine

  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    routines = Routines.list_routines()
    render(conn, :index, routines: routines)
  end

  def create(conn, %{"routine" => routine_params}) do
    with {:ok, %Routine{} = routine} <- Routines.create_routine(routine_params) do
      conn
      |> put_status(:created)
      |> render(:show, routine: routine)
    end
  end

  def show(conn, %{"id" => id}) do
    case Routines.get_routine(id) do
      {:ok, routine} ->
        render(conn, :show, routine: routine)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def update(conn, %{"id" => id, "routine" => routine_params}) do
    case Routines.get_routine(id) do
      {:ok, routine} ->
        with {:ok, %Routine{} = routine} <- Routines.update_routine(routine, routine_params) do
          render(conn, :show, routine: routine)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def delete(conn, %{"id" => id}) do
    case Routines.get_routine(id) do
      {:ok, routine} ->
        Routines.delete_routine(routine)
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def pause(conn, %{"id" => id}) do
    case Routines.get_routine(id) do
      {:ok, routine} ->
        with {:ok, %Routine{} = routine} <- Routines.pause_routine(routine) do
          render(conn, :show, routine: routine)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def resume(conn, %{"id" => id}) do
    case Routines.get_routine(id) do
      {:ok, routine} ->
        with {:ok, %Routine{} = routine} <- Routines.resume_routine(routine) do
          render(conn, :show, routine: routine)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def archive(conn, %{"id" => id}) do
    case Routines.get_routine(id) do
      {:ok, routine} ->
        with {:ok, %Routine{} = routine} <- Routines.archive_routine(routine) do
          render(conn, :show, routine: routine)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end
end
