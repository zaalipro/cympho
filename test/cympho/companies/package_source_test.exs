defmodule Cympho.Companies.PackageSourceTest do
  @moduledoc """
  The documented portable directory format and ref-pinned repository sources.

  Repository tests run against a real HTTP server on loopback rather than a
  stubbed client, so the Finch request path, status handling, and redirect
  refusal are all exercised for real.
  """

  use ExUnit.Case, async: false

  alias Cympho.Companies.PackageSource
  alias Cympho.Companies.PortablePackage

  @sha String.duplicate("a1b2c3d4", 5)

  defmodule FixturePlug do
    @moduledoc false
    import Plug.Conn

    def init(files), do: files

    def call(conn, files) do
      case Map.fetch(files, conn.request_path) do
        {:ok, {:redirect, location}} ->
          conn |> put_resp_header("location", location) |> send_resp(302, "")

        {:ok, {:status, status}} ->
          send_resp(conn, status, "")

        {:ok, body} when is_binary(body) ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        :error ->
          send_resp(conn, 404, "not found")
      end
    end
  end

  defp package do
    %{
      "version" => 1,
      "exported_at" => "2026-08-14T12:00:00Z",
      "company" => %{"name" => "Standard", "slug" => "standard"},
      "projects" => [%{"id" => "project-1", "name" => "Platform", "prefix" => "PLAT"}],
      "labels" => [%{"id" => "label-1", "name" => "bug"}]
    }
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "cympho-package-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp serve(files) do
    {:ok, pid} =
      start_supervised(
        {Bandit, plug: {FixturePlug, files}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    Application.put_env(:cympho, :package_source_base_url, "http://127.0.0.1:#{port}")
    on_exit(fn -> Application.delete_env(:cympho, :package_source_base_url) end)

    port
  end

  describe "directory format" do
    test "writes and reads back a package" do
      dir = Path.join(tmp_dir(), "pkg")

      assert {:ok, ^dir} = PackageSource.write_dir(package(), dir)
      assert File.exists?(Path.join(dir, "cympho-package.json"))
      assert File.exists?(Path.join(dir, "company.json"))
      assert File.exists?(Path.join(dir, "projects.json"))

      assert {:ok, loaded} = PackageSource.load_dir(dir)
      assert loaded["company"] == package()["company"]
      assert loaded["projects"] == package()["projects"]
      assert loaded["version"] == 1
      assert loaded["exported_at"] == "2026-08-14T12:00:00Z"
    end

    test "the manifest lists only the collections the package actually has" do
      dir = Path.join(tmp_dir(), "pkg")
      assert {:ok, _} = PackageSource.write_dir(package(), dir)

      manifest = dir |> Path.join("cympho-package.json") |> File.read!() |> Jason.decode!()

      assert manifest["format"] == PackageSource.format()
      assert Map.keys(manifest["files"]) |> Enum.sort() == ["company", "labels", "projects"]
      refute File.exists?(Path.join(dir, "issues.json"))
    end

    test "a selective export round-trips through the directory format" do
      dir = Path.join(tmp_dir(), "pkg")
      selective = Map.take(package(), ["version", "labels"])

      assert {:ok, _} = PackageSource.write_dir(selective, dir)
      assert {:ok, loaded} = PackageSource.load_dir(dir)

      # Package metadata always survives; only collections are selective.
      assert Map.keys(loaded) |> Enum.sort() == ["format", "labels", "version"]
    end

    test "rejects a missing or non-directory source" do
      assert {:error, "Package directory not found."} = PackageSource.load_dir("/nope/not/here")

      file = Path.join(tmp_dir(), "a.json")
      File.write!(file, "{}")
      assert {:error, "Package source must be a directory."} = PackageSource.load_dir(file)

      assert {:error, _} = PackageSource.load_dir("")
      assert {:error, _} = PackageSource.load_dir(<<"pkg", 0, "x">>)
    end

    test "rejects a manifest with the wrong format or version" do
      dir = tmp_dir()

      File.write!(
        Path.join(dir, "cympho-package.json"),
        Jason.encode!(%{"format" => "something-else", "version" => 1, "files" => %{}})
      )

      assert {:error, message} = PackageSource.load_dir(dir)
      assert message =~ "Unsupported package format"

      File.write!(
        Path.join(dir, "cympho-package.json"),
        Jason.encode!(%{"format" => PackageSource.format(), "version" => 99, "files" => %{}})
      )

      assert {:error, message} = PackageSource.load_dir(dir)
      assert message =~ "Unsupported package version"
    end

    test "a manifest cannot name an unknown collection" do
      dir = tmp_dir()

      File.write!(
        Path.join(dir, "cympho-package.json"),
        Jason.encode!(%{
          "format" => PackageSource.format(),
          "version" => 1,
          "files" => %{"passwords" => "passwords.json"}
        })
      )

      assert {:error, message} = PackageSource.load_dir(dir)
      assert message =~ "unknown collection"
    end

    test "a manifest cannot redirect a collection at an arbitrary path" do
      dir = tmp_dir()
      File.write!(Path.join(dir, "company.json"), Jason.encode!(%{"name" => "ok"}))

      for hostile <- ["../../etc/passwd", "/etc/passwd", "company.json.bak", "sub/company.json"] do
        File.write!(
          Path.join(dir, "cympho-package.json"),
          Jason.encode!(%{
            "format" => PackageSource.format(),
            "version" => 1,
            "files" => %{"company" => hostile}
          })
        )

        assert {:error, message} = PackageSource.load_dir(dir)
        assert message =~ "must use the standard filename"
      end
    end

    test "refuses a symlinked collection file" do
      dir = tmp_dir()
      outside = Path.join(tmp_dir(), "outside.json")
      File.write!(outside, Jason.encode!(%{"leaked" => true}))

      File.write!(
        Path.join(dir, "cympho-package.json"),
        Jason.encode!(%{
          "format" => PackageSource.format(),
          "version" => 1,
          "files" => %{"company" => "company.json"}
        })
      )

      :ok = File.ln_s(outside, Path.join(dir, "company.json"))

      assert {:error, message} = PackageSource.load_dir(dir)
      assert message =~ "symlink"
    end

    test "reports a declared file that is missing" do
      dir = tmp_dir()

      File.write!(
        Path.join(dir, "cympho-package.json"),
        Jason.encode!(%{
          "format" => PackageSource.format(),
          "version" => 1,
          "files" => %{"company" => "company.json"}
        })
      )

      assert {:error, message} = PackageSource.load_dir(dir)
      assert message =~ "missing"
    end

    test "reports invalid JSON without echoing the file contents" do
      dir = tmp_dir()

      File.write!(
        Path.join(dir, "cympho-package.json"),
        Jason.encode!(%{
          "format" => PackageSource.format(),
          "version" => 1,
          "files" => %{"company" => "company.json"}
        })
      )

      File.write!(Path.join(dir, "company.json"), "{not json, secret=hunter2")

      assert {:error, message} = PackageSource.load_dir(dir)
      assert message =~ "not valid JSON"
      refute message =~ "hunter2"
    end

    test "loads through the PortablePackage facade" do
      dir = Path.join(tmp_dir(), "pkg")
      assert {:ok, _} = PackageSource.write_dir(package(), dir)

      assert {:ok, loaded} = PortablePackage.load_source(:dir, dir)
      assert loaded["company"]["slug"] == "standard"
    end
  end

  describe "repository source ref pinning" do
    test "a ref is required" do
      assert {:error, message} = PackageSource.load_github("owner/name", [])
      assert message =~ "A ref is required"
    end

    test "a branch or tag is refused unless explicitly allowed" do
      assert {:error, message} = PackageSource.load_github("owner/name", ref: "main")
      assert message =~ "not a pinned commit SHA"
    end

    test "rejects path traversal in the repo, ref, and path" do
      assert {:error, _} = PackageSource.load_github("../../etc", ref: @sha)

      assert {:error, _} =
               PackageSource.load_github("owner/name", ref: "../..", allow_unpinned: true)

      assert {:error, message} =
               PackageSource.load_github("owner/name", ref: @sha, path: "../../etc/passwd")

      assert message =~ "traversal" or message =~ "unsupported characters"
    end

    test "rejects a malformed repository" do
      assert {:error, message} = PackageSource.load_github("no-slash", ref: @sha)
      assert message =~ "owner/name"
    end
  end

  describe "repository source over HTTP" do
    test "fetches a single-file package at a pinned commit" do
      serve(%{"/owner/name/#{@sha}/package.json" => Jason.encode!(package())})

      assert {:ok, loaded} =
               PackageSource.load_github("owner/name", ref: @sha, path: "package.json")

      assert loaded["company"]["slug"] == "standard"
    end

    test "fetches a manifest-driven directory package at a pinned commit" do
      manifest = %{
        "format" => PackageSource.format(),
        "version" => 1,
        "files" => %{"company" => "company.json", "labels" => "labels.json"}
      }

      serve(%{
        "/owner/name/#{@sha}/packages/std/cympho-package.json" => Jason.encode!(manifest),
        "/owner/name/#{@sha}/packages/std/company.json" => Jason.encode!(package()["company"]),
        "/owner/name/#{@sha}/packages/std/labels.json" => Jason.encode!(package()["labels"])
      })

      assert {:ok, loaded} =
               PackageSource.load_github("owner/name", ref: @sha, path: "packages/std")

      assert loaded["company"]["slug"] == "standard"
      assert [%{"name" => "bug"}] = loaded["labels"]
      assert loaded["version"] == 1
    end

    test "defaults to the manifest at the repository root" do
      manifest = %{
        "format" => PackageSource.format(),
        "version" => 1,
        "files" => %{"company" => "company.json"}
      }

      serve(%{
        "/owner/name/#{@sha}/cympho-package.json" => Jason.encode!(manifest),
        "/owner/name/#{@sha}/company.json" => Jason.encode!(package()["company"])
      })

      assert {:ok, loaded} = PackageSource.load_github("owner/name", ref: @sha)
      assert loaded["company"]["name"] == "Standard"
    end

    test "accepts a branch when unpinned refs are explicitly allowed" do
      serve(%{"/owner/name/main/package.json" => Jason.encode!(package())})

      assert {:ok, _loaded} =
               PackageSource.load_github("owner/name",
                 ref: "main",
                 path: "package.json",
                 allow_unpinned: true
               )
    end

    test "reports a missing file at the pinned ref" do
      serve(%{})

      assert {:error, message} =
               PackageSource.load_github("owner/name", ref: @sha, path: "package.json")

      assert message =~ "was not found"
    end

    test "refuses to follow a redirect off the package host" do
      serve(%{
        "/owner/name/#{@sha}/package.json" => {:redirect, "http://evil.test/payload.json"}
      })

      assert {:error, message} =
               PackageSource.load_github("owner/name", ref: @sha, path: "package.json")

      assert message =~ "refused a redirect"
    end

    test "surfaces a non-200 status without leaking the response" do
      serve(%{"/owner/name/#{@sha}/package.json" => {:status, 500}})

      assert {:error, message} =
               PackageSource.load_github("owner/name", ref: @sha, path: "package.json")

      assert message =~ "HTTP 500"
    end

    test "rejects a fetched file that is not a JSON object" do
      serve(%{"/owner/name/#{@sha}/package.json" => Jason.encode!([1, 2, 3])})

      assert {:error, message} =
               PackageSource.load_github("owner/name", ref: @sha, path: "package.json")

      assert message =~ "must contain a JSON object"
    end

    test "loads through the PortablePackage facade" do
      serve(%{"/owner/name/#{@sha}/package.json" => Jason.encode!(package())})

      assert {:ok, loaded} =
               PortablePackage.load_source(
                 :github,
                 {"owner/name", [ref: @sha, path: "package.json"]}
               )

      assert loaded["company"]["slug"] == "standard"
    end

    test "an unsupported source kind names the supported ones" do
      assert {:error, message} = PortablePackage.load_source(:ftp, "x")
      assert message =~ ":json, :path, :dir, or :github"
    end
  end
end
