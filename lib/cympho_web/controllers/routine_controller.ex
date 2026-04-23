defmodule CymphoWeb.RoutineController do
  use CymphoWeb, :controller
<<<<<<< HEAD

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
=======
  plug :accepts, ["json"]

  alias Cympho.Routines

  def index(conn, _params) do
    routines = Routines.list_routines()
    json(conn, %{data: Enum.map(routines, &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    routine = Routines.get_routine!(id)
    json(conn, %{data: serialize(routine)})
  end

  def create(conn, %{"routine" => routine_params}) do
    case Routines.create_routine(routine_params) do
      {:ok, routine} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize(routine)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def create(conn, params) do
    create(conn, %{"routine" => params})
  end

  def update(conn, %{"id" => id, "routine" => routine_params}) do
    routine = Routines.get_routine!(id)

    case Routines.update_routine(routine, routine_params) do
      {:ok, routine} ->
        json(conn, %{data: serialize(routine)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    update(conn, %{"id" => id, "routine" => params})
  end

  def delete(conn, %{"id" => id}) do
    routine = Routines.get_routine!(id)
    {:ok, _} = Routines.delete_routine(routine)
    json(conn, %{message: "deleted"})
  end

  def pause(conn, %{"id" => id}) do
    routine = Routines.get_routine!(id)
    case Routines.pause_routine(routine) do
      {:ok, paused} -> json(conn, %{data: serialize(paused)})
      {:error, reason} -> conn |> put_status(:conflict) |> json(%{error: reason})
>>>>>>> origin/LLM-341/routine-triggers
    end
  end

  def resume(conn, %{"id" => id}) do
<<<<<<< HEAD
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
=======
    routine = Routines.get_routine!(id)
    case Routines.resume_routine(routine) do
      {:ok, resumed} -> json(conn, %{data: serialize(resumed)})
      {:error, reason} -> conn |> put_status(:conflict) |> json(%{error: reason})
>>>>>>> origin/LLM-341/routine-triggers
    end
  end

  def archive(conn, %{"id" => id}) do
<<<<<<< HEAD
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
=======
    routine = Routines.get_routine!(id)
    case Routines.archive_routine(routine) do
      {:ok, archived} -> json(conn, %{data: serialize(archived)})
      {:error, reason} -> conn |> put_status(:conflict) |> json(%{error: reason})
    end
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key)
      end)
    end)
  end

  defp serialize(routine) do
    %{
      id: routine.id,
      name: routine.name,
      description: routine.description,
      status: routine.status,
      agent_id: routine.agent_id,
      project_id: routine.project_id,
      inserted_at: routine.inserted_at,
      updated_at: routine.updated_at
    }
  end
>>>>>>> origin/LLM-341/routine-triggers
end
