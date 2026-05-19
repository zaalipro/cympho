defmodule Cympho.RoutingTelemetryTest do
  use ExUnit.Case, async: false

  import Mock

  alias Cympho.Routing

  setup do
    parent = self()
    handler_id = "routing-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:cympho, :routing, :classified],
        fn name, measurements, metadata, _config ->
          send(parent, {:telemetry, name, measurements, metadata})
        end,
        nil
      )

    prior_enabled = Application.get_env(:cympho, :llm_router_enabled?)
    prior_key = Application.get_env(:cympho, :anthropic_api_key)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      put_or_delete(:llm_router_enabled?, prior_enabled)
      put_or_delete(:anthropic_api_key, prior_key)
    end)

    :ok
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:cympho, key)
  defp put_or_delete(key, val), do: Application.put_env(:cympho, key, val)

  test "emits :llm source on a happy classification" do
    Application.put_env(:cympho, :llm_router_enabled?, true)
    Application.put_env(:cympho, :anthropic_api_key, "test-key")

    body =
      Jason.encode!(%{
        "content" => [%{"type" => "text", "text" => "ceo"}]
      })

    with_mock Finch,
      build: fn _, _, _, _ -> :req end,
      request: fn :req, _, _ ->
        {:ok, %Finch.Response{status: 200, body: body, headers: []}}
      end do
      issue_id = Ecto.UUID.generate()

      assert {:ok, :ceo, :llm} =
               Routing.classify_role(%{
                 id: issue_id,
                 title: "Strategic vision: world domination",
                 description: ""
               })

      assert_receive {:telemetry, [:cympho, :routing, :classified], measurements, metadata}
      assert measurements.source == :llm
      assert is_integer(measurements.duration_ms)
      assert metadata.issue_id == issue_id
      assert metadata.classified_role == :ceo
    end
  end

  test "emits :fallback source when LLM is disabled" do
    Application.put_env(:cympho, :llm_router_enabled?, false)

    {:ok, role, source} =
      Routing.classify_role(%{
        id: Ecto.UUID.generate(),
        title: "Implement the login button",
        description: ""
      })

    assert source == :fallback
    assert role == :engineer

    assert_receive {:telemetry, [:cympho, :routing, :classified], measurements, _metadata}
    assert measurements.source == :fallback
  end
end
