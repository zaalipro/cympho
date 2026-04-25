defmodule CymphoWeb.Socket do
  use Phoenix.Socket

  channel "company:*", CymphoWeb.CompanyChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    with {:ok, claims} <- Cympho.AgentAuthJWT.verify_token(token),
         {:ok, company_id} <- Cympho.AgentAuthJWT.get_company_id(claims),
         {:ok, agent_id} <- Cympho.AgentAuthJWT.get_agent_id(claims) do
      {:ok,
       socket
       |> assign(:company_id, company_id)
       |> assign(:user_id, agent_id)
       |> assign(:auth_method, :jwt)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def connect(_params, socket, connect_info) do
    case connect_info[:session] do
      %{"user_id" => user_id, "company_id" => company_id}
      when is_binary(user_id) and is_binary(company_id) ->
        {:ok,
         socket
         |> assign(:company_id, company_id)
         |> assign(:user_id, user_id)
         |> assign(:auth_method, :session)}

      _ ->
        {:error, :unauthorized}
    end
  end

  @impl true
  def id(socket), do: "socket:#{socket.assigns.company_id}:#{socket.assigns.user_id}"
end
