defmodule CymphoWeb.RoutineTriggerController do
  use CymphoWeb, :controller

  alias Cympho.RoutineTriggers

  plug :accepts, ["json"]

  def fire(conn, %{"public_id" => public_id} = params) do
    secret = get_req_header(conn, "x-webhook-secret") |> List.first() || params["secret"]

    if is_nil(secret) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "missing webhook secret"})
    else
      case RoutineTriggers.fire_trigger_by_public_id(public_id, secret) do
        {:ok, %{issue: issue, run: run}} ->
          conn
          |> put_status(:ok)
          |> json(%{
            message: "trigger fired",
            run_id: run.id,
            issue_id: issue.id,
            issue_title: issue.title
          })

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "trigger not found"})

        {:error, :invalid_secret} ->
          conn
          |> put_status(:unauthorized)
          |> json(%{error: "invalid webhook secret"})

        {:error, :routine_paused} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "routine is paused"})

        {:error, :trigger_disabled} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "trigger is disabled"})

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "trigger fire failed", reason: inspect(reason)})
      end
    end
  end

  def rotate_secret(conn, %{"id" => id}) do
    case RoutineTriggers.get_trigger(id) do
      {:ok, trigger} ->
        case RoutineTriggers.rotate_webhook_secret(trigger) do
          {:ok, _trigger, new_secret} ->
            json(conn, %{message: "secret rotated", secret: new_secret})

          {:error, :not_webhook_trigger} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "not a webhook trigger"})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "failed to rotate secret", changeset: translate_errors(changeset)})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "trigger not found"})
    end
  end

  def index(conn, %{"routine_id" => routine_id}) do
    triggers = RoutineTriggers.list_triggers(routine_id)
    json(conn, %{data: Enum.map(triggers, &serialize_trigger/1)})
  end

  def show(conn, %{"id" => id}) do
    case RoutineTriggers.get_trigger(id) do
      {:ok, trigger} ->
        json(conn, %{data: serialize_trigger(trigger)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "trigger not found"})
    end
  end

  def create(conn, %{"routine_id" => routine_id, "type" => "schedule"} = params) do
    attrs = %{
      "routine_id" => routine_id,
      "cron_expression" => params["cron_expression"],
      "enabled" => Map.get(params, "enabled", true)
    }

    case RoutineTriggers.create_schedule_trigger(attrs) do
      {:ok, trigger} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_trigger(trigger)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def create(conn, %{"routine_id" => routine_id, "type" => "webhook"} = params) do
    attrs = %{
      "routine_id" => routine_id,
      "enabled" => Map.get(params, "enabled", true)
    }

    case RoutineTriggers.create_webhook_trigger(attrs) do
      {:ok, trigger, secret} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_trigger(trigger), secret: secret})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "type must be 'schedule' or 'webhook'"})
  end

  def update(conn, %{"id" => id} = params) do
    case RoutineTriggers.get_trigger(id) do
      {:ok, trigger} ->
        attrs = Map.take(params, ["cron_expression", "enabled"])

        case RoutineTriggers.update_trigger(trigger, attrs) do
          {:ok, updated} ->
            json(conn, %{data: serialize_trigger(updated)})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: translate_errors(changeset)})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "trigger not found"})
    end
  end

  def delete(conn, %{"id" => id}) do
    case RoutineTriggers.get_trigger(id) do
      {:ok, trigger} ->
        RoutineTriggers.delete_trigger(trigger)
        json(conn, %{message: "trigger deleted"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "trigger not found"})
    end
  end

  defp serialize_trigger(trigger) do
    %{
      id: trigger.id,
      type: trigger.type,
      cron_expression: trigger.cron_expression,
      public_id: trigger.public_id,
      enabled: trigger.enabled,
      routine_id: trigger.routine_id,
      inserted_at: trigger.inserted_at,
      updated_at: trigger.updated_at
    }
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key)
      end)
    end)
  end
end
