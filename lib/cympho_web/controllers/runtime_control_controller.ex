defmodule CymphoWeb.RuntimeControlController do
  use CymphoWeb, :controller

  alias Cympho.Companies
  alias CymphoWeb.UserAuth

  def pause(conn, params) do
    control(conn, params, fn company ->
      Companies.pause_company(company, "Paused from global runtime controls")
    end)
  end

  def stop(conn, params) do
    control(conn, params, fn company ->
      case Companies.stop_company_runtime(company, "Stopped from global runtime controls") do
        {:ok, updated, _runtime_stop} -> {:ok, updated}
        error -> error
      end
    end)
  end

  def resume(conn, params) do
    control(conn, params, &Companies.resume_company/1)
  end

  defp control(conn, params, fun) do
    with {:ok, company} <- current_company(conn),
         :ok <- authorize(conn, company),
         {:ok, _company} <- fun.(company) do
      conn
      |> put_flash(:info, success_message(conn.private.phoenix_action))
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

    if Companies.admin?(user.id, company.id) or Companies.is_board_member?(user.id, company.id) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp success_message(:pause), do: "Runtime paused. Active work has been released."
  defp success_message(:stop), do: "Runtime stopped. Active work has been released."
  defp success_message(:resume), do: "Runtime resumed."
  defp success_message(_action), do: "Runtime updated."

  defp return_to(params) do
    UserAuth.safe_return_path(params["return_to"]) || "/dashboard"
  end
end
