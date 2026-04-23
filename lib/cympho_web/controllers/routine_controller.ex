defmodule CymphoWeb.RoutineController do
  use CymphoWeb, :controller
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
    end
  end

  def resume(conn, %{"id" => id}) do
    routine = Routines.get_routine!(id)

    case Routines.resume_routine(routine) do
      {:ok, resumed} -> json(conn, %{data: serialize(resumed)})
      {:error, reason} -> conn |> put_status(:conflict) |> json(%{error: reason})
    end
  end

  def archive(conn, %{"id" => id}) do
    routine = Routines.get_routine!(id)

    case Routines.archive_routine(routine) do
      {:ok, archived} -> json(conn, %{data: serialize(archived)})
      {:error, reason} -> conn |> put_status(:conflict) |> json(%{error: reason})
    end
  end

  def run(conn, %{"id" => id}) do
    case Cympho.RoutineTriggers.manual_run(id, []) do
      {:ok, %{run: run, issue: issue}} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_run(run), issue_id: issue.id})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "routine not found"})

      {:error, :routine_paused} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "routine is paused"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "manual run failed", reason: inspect(reason)})
    end
  end

  def runs(conn, %{"id" => id}) do
    routine = Routines.get_routine!(id)
    limit = conn.params["limit"] |> parse_int() |> Kernel.||(50)
    runs = Cympho.RoutineTriggers.list_runs(routine.id, limit: limit)
    json(conn, %{data: Enum.map(runs, &serialize_run/1)})
  end

  defp parse_int(nil), do: nil
  defp parse_int(s) when is_binary(s), do: String.to_integer(s)
  defp parse_int(n) when is_integer(n), do: n

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

  defp serialize_run(run) do
    %{
      id: run.id,
      status: run.status,
      trigger_type: run.trigger_type,
      triggered_at: run.triggered_at,
      completed_at: run.completed_at,
      routine_id: run.routine_id,
      trigger_id: run.trigger_id,
      issue_id: run.issue_id,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end
end
