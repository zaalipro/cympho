defmodule CymphoWeb.Socket do
  use Phoenix.Socket

  alias Cympho.Authentication
  alias Cympho.Companies
  alias Cympho.Users
  alias CymphoWeb.ClientIP

  channel "company:*", CymphoWeb.CompanyChannel

  @impl true
  def connect(%{"token" => token}, socket, connect_info) do
    with {:ok, %{agent: agent, run: run}} <- Authentication.authenticate_heartbeat_token(token) do
      {:ok,
       socket
       |> assign(:company_id, agent.company_id)
       |> assign(:user_id, agent.id)
       |> assign(:run_id, run.id)
       |> assign(:auth_method, :jwt)
       |> assign(:ip_address, extract_ip(connect_info))}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def connect(_params, socket, connect_info) do
    case connect_info[:session] do
      %{"user_id" => user_id, "company_id" => company_id}
      when is_binary(user_id) and is_binary(company_id) ->
        with {:ok, user} <- Users.get_user(user_id),
             true <- Users.session_version_valid?(connect_info[:session]["session_version"], user),
             true <- Companies.has_access?(user_id, company_id) do
          {:ok,
           socket
           |> assign(:company_id, company_id)
           |> assign(:user_id, user_id)
           |> assign(:auth_method, :session)
           |> assign(:ip_address, extract_ip(connect_info))}
        else
          _ -> :error
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  @impl true
  def id(socket), do: "socket:#{socket.assigns.company_id}:#{socket.assigns.user_id}"

  def extract_ip(connect_info) do
    case connect_info[:peer_data] do
      %{address: peer_address} -> ClientIP.resolve(peer_address, connect_info[:x_headers])
      _ -> {127, 0, 0, 1}
    end
  end
end
