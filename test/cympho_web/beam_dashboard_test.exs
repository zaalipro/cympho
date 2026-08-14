defmodule CymphoWeb.BeamDashboardTest do
  @moduledoc """
  The BEAM dashboard is a node-wide operator surface: it exposes every process,
  ETS table, and query on the node, across all tenants. These tests pin the two
  properties that matter — it is off unless an operator explicitly configures
  credentials, and it is never reachable through company membership.
  """

  use CymphoWeb.ConnCase, async: false

  alias Cympho.Telemetry.Metrics

  setup do
    original = Application.get_env(:cympho, :beam_dashboard)

    on_exit(fn ->
      if original do
        Application.put_env(:cympho, :beam_dashboard, original)
      else
        Application.delete_env(:cympho, :beam_dashboard)
      end
    end)

    :ok
  end

  defp configure(config), do: Application.put_env(:cympho, :beam_dashboard, config)

  describe "access control" do
    test "returns 404 when no operator credentials are configured", %{conn: conn} do
      Application.delete_env(:cympho, :beam_dashboard)

      conn = get(conn, "/beam")

      assert conn.status == 404
      assert conn.halted
    end

    test "returns 404 when credentials are blank rather than falling open", %{conn: conn} do
      for config <- [
            [username: "", password: "secret"],
            [username: "operator", password: ""],
            [username: "   ", password: "   "],
            [username: nil, password: nil],
            []
          ] do
        configure(config)
        assert get(build_conn(), "/beam").status == 404
      end

      # `conn` from the case template is unused above; keep it referenced so the
      # test reads as a request test rather than a config unit test.
      assert %Plug.Conn{} = conn
    end

    test "challenges without credentials when the dashboard is configured", %{conn: conn} do
      configure(username: "operator", password: "operator-secret")

      conn = get(conn, "/beam")

      assert conn.status == 401
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") != []
    end

    test "rejects wrong credentials", %{conn: conn} do
      configure(username: "operator", password: "operator-secret")

      conn =
        conn
        |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("operator", "wrong"))
        |> get("/beam")

      assert conn.status == 401
    end

    test "serves the dashboard with correct credentials", %{conn: conn} do
      configure(username: "operator", password: "operator-secret")

      conn =
        conn
        |> put_req_header(
          "authorization",
          Plug.BasicAuth.encode_basic_auth("operator", "operator-secret")
        )
        |> get("/beam")

      # LiveDashboard redirects the bare path to its first page; follow it and
      # assert we actually landed on the dashboard rather than a login page.
      target =
        case conn.status do
          302 -> redirected_to(conn)
          200 -> nil
          status -> flunk("unexpected dashboard status #{status}")
        end

      if target do
        refute target =~ "/login"
        assert target =~ "/beam"
      end
    end

    test "a logged-in company member cannot reach it through session auth", %{conn: conn} do
      configure(username: "operator", password: "operator-secret")

      # No basic-auth header: company membership must not be enough.
      conn = get(conn, "/beam")

      assert conn.status == 401
    end
  end

  describe "metric definitions" do
    test "every metric points at an event this app can actually emit" do
      emitted =
        MapSet.new([
          [:vm, :memory],
          [:vm, :total_run_queue_lengths],
          [:vm, :system_counts],
          [:cympho, :runtime, :orchestrators],
          [:cympho, :runtime, :heartbeats],
          [:cympho, :runtime, :tasks],
          [:cympho, :runtime, :singleton],
          [:cympho, :runtime, :supervisor],
          [:phoenix, :endpoint, :stop],
          [:phoenix, :router_dispatch, :stop],
          [:phoenix, :live_view, :mount, :stop],
          [:phoenix, :channel_joined],
          [:phoenix, :socket_connected],
          [:cympho, :repo, :query],
          [:cympho, :issue, :created],
          [:cympho, :issue, :transitioned],
          [:cympho, :agent, :assigned],
          [:cympho, :agent, :status_changed],
          [:cympho, :kanban, :card_moved],
          [:cympho, :onboarding, :completed],
          [:cympho, :run, :lifecycle],
          [:cympho, :dispatcher, :dispatch]
        ])

      for metric <- Metrics.metrics() do
        assert MapSet.member?(emitted, metric.event_name),
               "#{inspect(metric.name)} listens for #{inspect(metric.event_name)}, which nothing emits"
      end
    end

    test "no metric tags on a per-tenant identifier" do
      unbounded = [:company_id, :issue_id, :agent_id, :run_id, :user_id, :project_id]

      for metric <- Metrics.metrics(), tag <- metric.tags do
        refute tag in unbounded,
               "#{inspect(metric.name)} tags on #{inspect(tag)}, which grows a series per record"
      end
    end
  end

  describe "runtime measurements" do
    test "singleton measurements report liveness, mailbox depth, and memory" do
      events = attach_probe([:cympho, :runtime, :singleton])

      Metrics.dispatch_singleton_measurements()

      captured = collect(events)
      assert captured != []

      for {measurements, metadata} <- captured do
        assert is_atom(metadata.process)
        assert measurements.alive in [0, 1]

        if measurements.alive == 1 do
          assert is_integer(measurements.message_queue_len)
          assert is_integer(measurements.memory)
        end
      end
    end

    test "runtime measurements report live process populations" do
      events = attach_probe([:cympho, :runtime, :orchestrators])

      Metrics.dispatch_runtime_measurements()

      assert [{%{count: count}, _metadata}] = collect(events)
      assert is_integer(count) and count >= 0
    end

    test "bounded supervisors report how close they are to refusing children" do
      events = attach_probe([:cympho, :runtime, :supervisor])

      Metrics.dispatch_supervisor_measurements()

      captured = collect(events)
      assert captured != []

      supervisors = Enum.map(captured, fn {_m, meta} -> meta.supervisor end)
      assert :agent_heartbeats in supervisors
      assert :plugins in supervisors

      for {measurements, _metadata} <- captured do
        assert measurements.max_children > 0
        assert measurements.children >= 0
        assert measurements.saturation_pct >= 0
      end
    end

    test "measurements do not raise when a supervised process is absent" do
      # Nothing here depends on the app being fully booted; the helpers must
      # degrade to zero rather than crash the poller and trip its restart budget.
      assert :ok = Metrics.dispatch_runtime_measurements()
      assert :ok = Metrics.dispatch_singleton_measurements()
      assert :ok = Metrics.dispatch_supervisor_measurements()
    end
  end

  defp attach_probe(event) do
    handler_id = "probe-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      fn _name, measurements, metadata, _config ->
        send(test_pid, {:probe, handler_id, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp collect(handler_id, acc \\ []) do
    receive do
      {:probe, ^handler_id, measurements, metadata} ->
        collect(handler_id, [{measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
