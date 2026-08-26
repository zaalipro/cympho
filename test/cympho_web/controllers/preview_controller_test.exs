defmodule CymphoWeb.PreviewControllerTest do
  use CymphoWeb.ConnCase, async: false

  import Mock

  alias Cympho.Projects
  alias Cympho.Workspaces
  alias Cympho.Workspaces.PreviewUrl

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn)
    unique = System.unique_integer([:positive])

    {:ok, project} =
      Projects.create_project(%{
        name: "Preview Project #{unique}",
        prefix: project_prefix("PV", unique),
        company_id: company.id
      })

    {:ok, workspace} =
      Workspaces.create_project_workspace(%{
        name: "Preview workspace #{unique}",
        company_id: company.id,
        project_id: project.id
      })

    {:ok, execution_workspace} =
      Workspaces.create_execution_workspace(%{
        name: "Preview exec #{unique}",
        status: "open",
        company_id: company.id,
        project_id: project.id,
        project_workspace_id: workspace.id
      })

    %{
      conn: conn,
      company: company,
      project: project,
      workspace: workspace,
      execution_workspace: execution_workspace,
      unique: unique
    }
  end

  test "preview href contains /api/preview/", %{
    conn: conn,
    company: company,
    project: project,
    workspace: workspace,
    execution_workspace: execution_workspace,
    unique: unique
  } do
    {:ok, service} =
      create_service(company, project, workspace, execution_workspace, unique,
        status: "running",
        port: 4329
      )

    conn = get(conn, "/api/preview/#{service.id}")
    assert %{"data" => data} = json_response(conn, 200)
    assert data["preview_url"] =~ "/api/preview/"
    preview_uri = URI.parse(data["preview_url"])
    assert preview_uri.host == PreviewUrl.preview_host()
    assert preview_uri.host != conn.host
    assert preview_uri.path =~ ~r{^/api/preview/#{service.id}/[^/]+/proxy$}
    refute data["preview_url"] =~ service.preview_ref
    refute data["preview_url"] =~ ~r{(?<!/api)/preview/#{service.id}(?:/|$)}
  end

  test "signed proxy capability works only on the dedicated preview host", %{
    conn: conn,
    company: company,
    project: project,
    workspace: workspace,
    execution_workspace: execution_workspace,
    unique: unique
  } do
    {:ok, service} =
      create_service(company, project, workspace, execution_workspace, unique,
        status: "running",
        port: 4329
      )

    path = preview_path(service)

    app_origin_conn = get(conn, path)
    assert app_origin_conn.status == 404

    preview_origin_conn = conn |> on_preview_host() |> get("/api/preview/#{service.id}")
    assert preview_origin_conn.status == 404
  end

  test "preview route accepts an ordinary browser HTML request", context do
    {:ok, service} =
      create_service(
        context.company,
        context.project,
        context.workspace,
        context.execution_workspace,
        context.unique,
        status: "running",
        port: 4329
      )

    with_mock Finch, [:passthrough],
      stream_while: fn _request, Cympho.Finch, initial, reducer, _opts ->
        state =
          [
            {:status, 200},
            {:headers, [{"content-type", "text/html; charset=utf-8"}]},
            {:data, "<h1>Preview</h1>"}
          ]
          |> Enum.reduce(initial, fn event, state ->
            {:cont, state} = reducer.(event, state)
            state
          end)

        {:ok, state}
      end do
      conn =
        context.conn
        |> put_req_header("accept", "text/html")
        |> on_preview_host()
        |> get(preview_path(service))

      assert conn.status == 200
      assert conn.resp_body == "<h1>Preview</h1>"
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end
  end

  test "tampered and expired preview capabilities are rejected", context do
    {:ok, service} =
      create_service(
        context.company,
        context.project,
        context.workspace,
        context.execution_workspace,
        context.unique,
        status: "running",
        port: 4329
      )

    token = PreviewUrl.sign_capability(service)
    first = binary_part(token, 0, 1)
    replacement = if first == "A", do: "B", else: "A"
    tampered = replacement <> binary_part(token, 1, byte_size(token) - 1)

    tampered_conn =
      context.conn
      |> on_preview_host()
      |> get("/api/preview/#{service.id}/#{tampered}/proxy")

    assert %{"error" => "Runtime service not found"} = json_response(tampered_conn, 404)

    expired_token =
      PreviewUrl.sign_capability(service,
        signed_at: System.system_time(:second) - 301,
        max_age: 300
      )

    expired_conn =
      context.conn
      |> on_preview_host()
      |> get("/api/preview/#{service.id}/#{expired_token}/proxy")

    assert %{"error" => "Runtime service not found"} = json_response(expired_conn, 404)
  end

  test "proxy does not raise and forwards a path that is not id/proxy/...", %{
    conn: conn,
    company: company,
    project: project,
    workspace: workspace,
    execution_workspace: execution_workspace,
    unique: unique
  } do
    {:ok, service} =
      create_service(company, project, workspace, execution_workspace, unique,
        status: "running",
        port: 4329
      )

    test_pid = self()

    with_mock Finch, [:passthrough],
      stream_while: fn request, Cympho.Finch, initial, reducer, _opts ->
        send(test_pid, {:finch_request, request})

        state =
          [
            {:status, 200},
            {:headers,
             [
               {"content-type", "text/plain"},
               {"set-cookie", "upstream=secret"},
               {"connection", "keep-alive"},
               {"x-upstream-secret", "secret"}
             ]},
            {:data, "ok"}
          ]
          |> Enum.reduce(initial, fn event, state ->
            {:cont, state} = reducer.(event, state)
            state
          end)

        {:ok, state}
      end do
      conn =
        conn
        |> delete_req_header("authorization")
        |> put_req_header("cookie", "session=secret")
        |> put_req_header("x-forwarded-for", "127.0.0.1")
        |> put_req_header("x-preview-secret", "secret")
        |> on_preview_host()
        |> get(preview_path(service, "/app"))

      assert conn.status == 200
      assert conn.resp_body == "ok"
      assert get_resp_header(conn, "content-type") == ["text/plain"]

      refute Enum.any?(
               get_resp_header(conn, "set-cookie"),
               &String.contains?(&1, "upstream=secret")
             )

      assert get_resp_header(conn, "connection") == []
      assert get_resp_header(conn, "x-upstream-secret") == []
    end

    assert_receive {:finch_request, request}
    assert request.host == "127.0.0.1"
    assert request.port == 4329
    assert request.path == "/app"
    refute request.path =~ "#{service.id}/proxy"
    refute String.contains?(request.host <> request.path, "#{service.id}/proxy")
    assert request.body == ""

    header_names = Enum.map(request.headers, fn {name, _} -> String.downcase(name) end)
    refute "authorization" in header_names
    refute "cookie" in header_names
    refute "host" in header_names
    refute "x-forwarded-for" in header_names
    refute "x-preview-secret" in header_names
  end

  test "metadata URL cannot become the Finch target because url is ignored", %{
    conn: conn,
    company: company,
    project: project,
    workspace: workspace,
    execution_workspace: execution_workspace,
    unique: unique
  } do
    metadata_url = "http://169.254.169.254/latest/meta-data"

    {:ok, service} =
      create_service(company, project, workspace, execution_workspace, unique,
        status: "running",
        port: 4000,
        url: metadata_url
      )

    assert PreviewUrl.get_target_url(service) == "http://127.0.0.1:4000"
    refute PreviewUrl.get_target_url(service) == metadata_url

    conn_show = get(conn, "/api/preview/#{service.id}")
    assert %{"data" => data} = json_response(conn_show, 200)
    assert data["target_url"] == "http://127.0.0.1:4000"

    assert URI.parse(data["preview_url"]).path =~
             ~r{^/api/preview/#{service.id}/[^/]+/proxy$}

    refute data["target_url"] =~ "169.254.169.254"

    test_pid = self()

    with_mock Finch, [:passthrough],
      stream_while: fn request, Cympho.Finch, initial, reducer, _opts ->
        send(test_pid, {:finch_request, request})

        state =
          [{:status, 200}, {:headers, [{"content-type", "text/plain"}]}, {:data, "ok"}]
          |> Enum.reduce(initial, fn event, state ->
            {:cont, state} = reducer.(event, state)
            state
          end)

        {:ok, state}
      end do
      conn = conn |> on_preview_host() |> get(preview_path(service, "/latest/meta-data"))

      assert conn.status == 200
    end

    assert_receive {:finch_request, request}
    assert request.host == "127.0.0.1"
    assert request.port == 4000
    refute request.host == "169.254.169.254"
    refute to_string(request.host) =~ "169.254"
  end

  test "service without an issued preview identity is not proxyable", %{
    conn: conn,
    company: company,
    project: project,
    workspace: workspace,
    execution_workspace: execution_workspace,
    unique: unique
  } do
    {:ok, service} =
      create_service(company, project, workspace, execution_workspace, unique,
        status: "running",
        port: nil
      )

    conn =
      conn
      |> on_preview_host()
      |> get("/api/preview/#{service.id}/invalid-capability/proxy/app")

    assert %{"error" => "Runtime service not found"} = json_response(conn, 404)
  end

  test "proxy stops an oversized upstream response before buffering its body", %{
    conn: conn,
    company: company,
    project: project,
    workspace: workspace,
    execution_workspace: execution_workspace,
    unique: unique
  } do
    {:ok, service} =
      create_service(company, project, workspace, execution_workspace, unique,
        status: "running",
        port: 4329
      )

    with_mock Finch, [:passthrough],
      stream_while: fn _request, Cympho.Finch, initial, reducer, _opts ->
        {:cont, state} = reducer.({:status, 200}, initial)
        {:cont, state} = reducer.({:headers, []}, state)
        first_chunk = :binary.copy(<<0>>, 8 * 1024 * 1024)
        second_chunk = :binary.copy(<<0>>, 8 * 1024 * 1024 + 1)
        {:cont, state} = reducer.({:data, first_chunk}, state)
        {:halt, state} = reducer.({:data, second_chunk}, state)

        {:ok, state}
      end do
      conn = conn |> on_preview_host() |> get(preview_path(service, "/large.bin"))

      assert %{"error" => "Preview response exceeds the allowed size"} =
               json_response(conn, 502)
    end
  end

  test "proxy rejects an oversized response header set", %{
    conn: conn,
    company: company,
    project: project,
    workspace: workspace,
    execution_workspace: execution_workspace,
    unique: unique
  } do
    {:ok, service} =
      create_service(company, project, workspace, execution_workspace, unique,
        status: "running",
        port: 4329
      )

    with_mock Finch, [:passthrough],
      stream_while: fn _request, Cympho.Finch, initial, reducer, _opts ->
        {:cont, state} = reducer.({:status, 200}, initial)
        headers = Enum.map(1..101, &{"x-preview-#{&1}", "value"})
        {:halt, state} = reducer.({:headers, headers}, state)
        {:ok, state}
      end do
      conn = conn |> on_preview_host() |> get(preview_path(service, "/headers"))
      assert %{"error" => "Failed to proxy request"} = json_response(conn, 502)
    end
  end

  defp preview_path(service, suffix \\ "") do
    service
    |> PreviewUrl.generate_preview_url("http://localhost")
    |> URI.parse()
    |> Map.fetch!(:path)
    |> Kernel.<>(suffix)
  end

  defp on_preview_host(conn) do
    Map.put(conn, :host, PreviewUrl.preview_host())
  end

  defp create_service(_company, _project, _workspace, execution_workspace, unique, attrs) do
    create_attrs =
      Map.merge(
        %{service_name: "Preview svc #{unique}"},
        attrs |> Map.new() |> Map.drop([:status, :port, :url])
      )

    with {:ok, service} <- Workspaces.create_runtime_service(execution_workspace, create_attrs) do
      case {Keyword.get(attrs, :status), Keyword.get(attrs, :port)} do
        {"running", port} when is_integer(port) ->
          Workspaces.issue_service_preview(service, port, %{url: Keyword.get(attrs, :url)})

        {"running", _port} ->
          Workspaces.mark_service_running(service)

        _ ->
          {:ok, service}
      end
    end
  end

  defp project_prefix(base, unique) do
    suffix =
      unique
      |> Integer.digits(26)
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 8)

    base <> suffix
  end
end
