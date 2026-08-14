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
    assert data["preview_url"] =~ "/api/preview/#{service.id}/proxy"
    refute data["preview_url"] =~ ~r{(?<!/api)/preview/#{service.id}(?:/|$)}
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
      request: fn request, Cympho.Finch, _opts ->
        send(test_pid, {:finch_request, request})
        {:ok, %Finch.Response{status: 200, body: "ok", headers: [{"content-type", "text/plain"}]}}
      end do
      conn =
        conn
        |> put_req_header("cookie", "session=secret")
        |> get("/api/preview/#{service.id}/proxy/app")

      assert conn.status == 200
      assert conn.resp_body == "ok"
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
    assert data["preview_url"] =~ "/api/preview/#{service.id}/proxy"
    refute data["target_url"] =~ "169.254.169.254"

    test_pid = self()

    with_mock Finch, [:passthrough],
      request: fn request, Cympho.Finch, _opts ->
        send(test_pid, {:finch_request, request})
        {:ok, %Finch.Response{status: 200, body: "ok", headers: [{"content-type", "text/plain"}]}}
      end do
      conn = get(conn, "/api/preview/#{service.id}/proxy/latest/meta-data")
      assert conn.status == 200
    end

    assert_receive {:finch_request, request}
    assert request.host == "127.0.0.1"
    assert request.port == 4000
    refute request.host == "169.254.169.254"
    refute to_string(request.host) =~ "169.254"
  end

  test "missing or invalid port returns 403 JSON", %{
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

    conn = get(conn, "/api/preview/#{service.id}/proxy/app")
    assert %{"error" => "Proxy target address is not allowed"} = json_response(conn, 403)
  end

  defp create_service(company, project, workspace, execution_workspace, unique, attrs) do
    Workspaces.create_runtime_service(
      Map.merge(
        %{
          service_name: "Preview svc #{unique}",
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: workspace.id,
          execution_workspace_id: execution_workspace.id
        },
        Map.new(attrs)
      )
    )
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
