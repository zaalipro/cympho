defmodule CymphoWeb.RuntimeControlController do
  use CymphoWeb, :controller

  require Logger

  alias Cympho.AuditTrail
  alias Cympho.CompanyRBAC
  alias Cympho.Companies
  alias CymphoWeb.UserAuth

  def low_power(conn, params) do
    control(conn, params, fn company ->
      Companies.enter_low_power_mode(company, "Low power from global runtime controls")
    end)
  end

  def pause(conn, params) do
    control(conn, params, fn company ->
      Companies.pause_company_runtime(company, "Paused from global runtime controls")
    end)
  end

  def stop(conn, params) do
    control(conn, params, fn company ->
      Companies.stop_company_runtime(company, "Stopped from global runtime controls")
    end)
  end

  def resume(conn, params) do
    control(conn, params, &Companies.resume_company/1)
  end

  defp control(conn, params, fun) do
    with {:ok, company} <- current_company(conn),
         :ok <- authorize(conn, company),
         {:ok, runtime_result} <- run_control(fun, company) do
      record_runtime_control_event(conn, company, conn.private.phoenix_action, runtime_result)

      conn
      |> put_flash(:info, success_message(conn.private.phoenix_action, runtime_result))
      |> redirect(to: return_to(params))
    else
      {:error, :forbidden} ->
        conn
        |> put_flash(:error, "Only owners, admins, or board members can control runtime.")
        |> redirect(to: return_to(params))

      {:error, :no_company} ->
        conn
        |> put_flash(:error, "Choose a company before controlling runtime.")
        |> redirect(to: return_to(params))

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Runtime control failed.")
        |> redirect(to: return_to(params))
    end
  end

  defp current_company(conn) do
    user = conn.assigns[:current_user]

    company_id =
      case conn.assigns[:current_company] do
        %{id: id} when is_binary(id) -> id
        _ -> get_session(conn, :company_id)
      end

    cond do
      is_nil(user) or not is_binary(company_id) ->
        {:error, :no_company}

      not Companies.has_access?(user.id, company_id) ->
        {:error, :no_company}

      true ->
        {:ok, Companies.get_company!(company_id)}
    end
  end

  defp authorize(conn, company) do
    user = conn.assigns[:current_user]

    if CompanyRBAC.manager?(user.id, company.id) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp run_control(fun, company) do
    case fun.(company) do
      {:ok, _company, runtime_result} -> {:ok, runtime_result}
      {:ok, _company} -> {:ok, nil}
      error -> error
    end
  end

  defp success_message(:pause, %{} = result) do
    sessions = Map.get(result, :orchestrators_stopped, 0)
    released = Map.get(result, :issues_released, 0)
    runs = Map.get(result, :runs_cancelled, 0)

    "Runtime paused. Stopped #{count_phrase(sessions, "harness session")}, released #{count_phrase(released, "active issue")}, cancelled #{count_phrase(runs, "run")}, and preserved queued wakes." <>
      adapter_session_suffix(result)
  end

  defp success_message(:pause, _result),
    do: "Runtime paused. Active work has been released; queued wakes are preserved."

  defp success_message(:stop, %{} = result) do
    sessions = Map.get(result, :orchestrators_stopped, 0)
    released = Map.get(result, :issues_released, 0)
    runs = Map.get(result, :runs_cancelled, 0)
    wakes = Map.get(result, :wakes_cancelled, 0)

    "Runtime stopped. Stopped #{count_phrase(sessions, "harness session")}, released #{count_phrase(released, "active issue")}, cancelled #{count_phrase(runs, "run")}, and cancelled #{count_phrase(wakes, "queued wake")}." <>
      adapter_session_suffix(result)
  end

  defp success_message(:stop, _result),
    do: "Runtime stopped. Active work released; queued wakes cancelled."

  defp success_message(:low_power, _result),
    do: "Runtime set to low power. Only high and critical queued work will auto-dispatch."

  defp success_message(:resume, _result), do: "Runtime resumed."
  defp success_message(_action, _result), do: "Runtime updated."

  defp count_phrase(1, label), do: "1 #{label}"
  defp count_phrase(count, label), do: "#{count} #{label}s"

  defp adapter_session_suffix(%{} = result) do
    requested = Map.get(result, :adapter_sessions_cancel_requested, 0)
    confirmed = Map.get(result, :adapter_sessions_cancel_confirmed, 0)
    still_registered = Map.get(result, :adapter_sessions_still_registered, 0)

    cond do
      requested == 0 ->
        ""

      still_registered > 0 ->
        " Confirmed #{count_phrase(confirmed, "adapter session")} stopped; #{count_phrase(still_registered, "adapter session")} still registered."

      true ->
        " Confirmed #{count_phrase(confirmed, "adapter session")} stopped."
    end
  end

  defp adapter_session_suffix(_result), do: ""

  defp record_runtime_control_event(conn, company, action, runtime_result) do
    user = conn.assigns[:current_user]

    attrs = %{
      company_id: company.id,
      event_type: runtime_control_event_type(action),
      actor_type: "user",
      actor_id: user.id,
      resource_type: "company",
      resource_id: company.id,
      payload: runtime_control_payload(action, runtime_result),
      ip_address: remote_ip(conn)
    }

    case AuditTrail.record_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[RuntimeControlController] failed to write runtime control audit event: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp runtime_control_event_type(:pause), do: "company_runtime_paused"
  defp runtime_control_event_type(:low_power), do: "company_runtime_low_power"
  defp runtime_control_event_type(:resume), do: "company_runtime_resumed"
  defp runtime_control_event_type(:stop), do: "company_runtime_stopped"

  defp runtime_control_payload(action, %{} = result) do
    %{
      "action" => to_string(action),
      "orchestrators_stopped" => Map.get(result, :orchestrators_stopped, 0),
      "adapter_sessions_cancel_requested" =>
        Map.get(result, :adapter_sessions_cancel_requested, 0),
      "adapter_sessions_cancel_confirmed" =>
        Map.get(result, :adapter_sessions_cancel_confirmed, 0),
      "adapter_sessions_still_registered" =>
        Map.get(result, :adapter_sessions_still_registered, 0),
      "issues_released" => Map.get(result, :issues_released, 0),
      "runs_cancelled" => Map.get(result, :runs_cancelled, 0),
      "wakes_cancelled" => Map.get(result, :wakes_cancelled, 0),
      "errors" => inspect(Map.get(result, :errors, []))
    }
  end

  defp runtime_control_payload(action, _result), do: %{"action" => to_string(action)}

  defp remote_ip(%Plug.Conn{remote_ip: remote_ip}) when is_tuple(remote_ip) do
    remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp remote_ip(_conn), do: nil

  defp return_to(params) do
    UserAuth.safe_return_path(params["return_to"]) || "/dashboard"
  end
end
