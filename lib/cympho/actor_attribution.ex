defmodule Cympho.ActorAttribution do
  @moduledoc """
  Helper module for extracting and normalizing actor information across the system.

  Provides consistent actor attribution for:
  - Tool call traces
  - Governance audit logs
  - Activity logs
  - Other system events requiring actor tracking
  """

  @nil_uuid "00000000-0000-0000-0000-000000000000"

  @type actor :: %{
          type: String.t(),
          id: String.t() | nil
        }

  @doc """
  Extracts actor information from various actor representations.

  ## Examples

      iex> ActorAttribution.extract_actor(%{"id" => "123", "type" => "user"})
      %{type: "user", id: "123"}

      iex> ActorAttribution.extract_actor(%Cympho.Agents.Agent{id: "456"})
      %{type: "agent", id: "456"}

      iex> ActorAttribution.extract_actor(nil)
      %{type: "system", id: nil}
  """
  @spec extract_actor(any()) :: actor()
  def extract_actor(nil), do: %{type: "system", id: @nil_uuid}

  def extract_actor(%{__struct__: struct_type, id: id}) when is_binary(id) do
    type = struct_name_to_actor_type(struct_type)
    %{type: type, id: id}
  end

  def extract_actor(%{id: id, type: type}) when is_binary(id) and is_binary(type) do
    %{type: type, id: id}
  end

  def extract_actor(%{"id" => id, "type" => type}) when is_binary(id) and is_binary(type) do
    %{type: type, id: id}
  end

  def extract_actor({type, id}) when is_binary(type) and is_binary(id) do
    actor_id = if valid_uuid?(id), do: id, else: @nil_uuid
    %{type: String.downcase(type), id: actor_id}
  end

  def extract_actor(%{actor_type: type, actor_id: id}) do
    %{type: type, id: id}
  end

  def extract_actor(%{"actor_type" => type, "actor_id" => id}) do
    %{type: type, id: id}
  end

  def extract_actor(_), do: %{type: "system", id: @nil_uuid}

  @doc """
  Converts actor information to the format expected by database schemas.

  ## Examples

      iex> ActorAttribution.to_db_attrs(%{type: "agent", id: "123"})
      %{actor_type: "agent", actor_id: "123"}

      iex> ActorAttribution.to_db_attrs(%{type: "system", id: nil})
      %{actor_type: "system", actor_id: nil}
  """
  @spec to_db_attrs(actor()) :: map()
  def to_db_attrs(%{type: type, id: id}) do
    %{
      actor_type: type,
      actor_id: id
    }
  end

  @doc """
  Normalizes actor type to ensure it's one of the valid types.

  ## Examples

      iex> ActorAttribution.normalize_actor_type("Agent")
      "agent"

      iex> ActorAttribution.normalize_actor_type("USER")
      "user"

      iex> ActorAttribution.normalize_actor_type("invalid")
      "system"
  """
  @spec normalize_actor_type(String.t() | atom()) :: String.t()
  def normalize_actor_type(type) when is_atom(type), do: normalize_actor_type(to_string(type))

  def normalize_actor_type(type) when is_binary(type) do
    normalized = String.downcase(type)

    case normalized do
      "user" -> "user"
      "agent" -> "agent"
      "system" -> "system"
      _ -> "system"
    end
  end

  @doc """
  Determines if an actor is of a specific type.

  ## Examples

      iex> ActorAttribution.is_actor_type?(%{type: "agent"}, "agent")
      true

      iex> ActorAttribution.is_actor_type?(%{type: "user"}, "agent")
      false
  """
  @spec is_actor_type?(actor(), String.t()) :: boolean()
  def is_actor_type?(%{type: type}, check_type), do: type == check_type

  @doc """
  Validates that actor_id is a valid UUID format.
  """
  @spec valid_uuid?(String.t()) :: boolean()
  def valid_uuid?(s) when is_binary(s) do
    String.match?(s, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

  def valid_uuid?(_), do: false

  # Private helper to convert struct names to actor types
  defp struct_name_to_actor_type(struct) do
    struct
    |> Module.split()
    |> List.last()
    |> String.downcase()
  end
end
