defmodule CymphoWeb.Socket do
  use Phoenix.Socket

  alias Cympho.Companies

  channel "company:*", CymphoWeb.CompanyChannel

  @impl true
  def connect(%{"token" => token}, socket, connect_info) do
    with {:ok, claims} <- Cympho.AgentAuthJWT.verify_token(token),
         {:ok, company_id} <- Cympho.AgentAuthJWT.get_company_id(claims),
         {:ok, agent_id} <- Cympho.AgentAuthJWT.get_agent_id(claims) do
      {:ok,
       socket
       |> assign(:company_id, company_id)
       |> assign(:user_id, agent_id)
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
        if Companies.has_access?(user_id, company_id) do
          {:ok,
           socket
           |> assign(:company_id, company_id)
           |> assign(:user_id, user_id)
           |> assign(:auth_method, :session)
           |> assign(:ip_address, extract_ip(connect_info))}
        else
          :error
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  @impl true
  def id(socket), do: "socket:#{socket.assigns.company_id}:#{socket.assigns.user_id}"

  def extract_ip(connect_info) do
    case forwarded_address(connect_info[:x_headers]) do
      {:ok, address} ->
        address

      :error ->
        case connect_info[:peer_data] do
          %{address: address} -> address
          _ -> {127, 0, 0, 1}
        end
    end
  end

  defp forwarded_address(headers) when is_list(headers) do
    value = header_value(headers, "x-forwarded-for") || header_value(headers, "x-real-ip")
    parse_ip(value)
  end

  defp forwarded_address(_headers), do: :error

  defp header_value(headers, name) do
    Enum.find_value(headers, fn
      {header, value} when is_binary(header) and is_binary(value) ->
        if String.downcase(header) == name, do: value

      _ ->
        nil
    end)
  end

  defp parse_ip(value) when is_binary(value) do
    value
    |> String.split(",", parts: 2)
    |> hd()
    |> String.trim()
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp parse_ip(_value), do: :error
end
