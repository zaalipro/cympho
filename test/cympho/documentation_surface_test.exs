defmodule Cympho.DocumentationSurfaceTest do
  use ExUnit.Case, async: true

  @required_docs [
    "docs/QUICKSTART.md",
    "docs/OPERATIONS.md",
    "docs/OBSERVABILITY.md",
    "SECURITY.md",
    "CONTRIBUTING.md",
    "ROADMAP.md"
  ]

  test "README links every adoption and operator document" do
    readme = File.read!("README.md")

    for path <- @required_docs do
      assert File.regular?(path), "missing #{path}"
      assert readme =~ path, "README does not link #{path}"
    end
  end

  test "README local Markdown links resolve to files" do
    readme = File.read!("README.md")

    readme
    |> then(&Regex.scan(~r/\[[^\]]+\]\(([^)#]+\.md)(?:#[^)]+)?\)/, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.reject(&String.starts_with?(&1, ["http://", "https://"]))
    |> Enum.each(fn path ->
      assert File.regular?(path), "README links missing Markdown file #{path}"
    end)
  end

  test "quickstart uses the configured development port and safe review mode" do
    quickstart = File.read!("docs/QUICKSTART.md")

    assert quickstart =~ "http://localhost:4329"
    assert quickstart =~ "CYMPHO_ORCHESTRATOR_ENABLED=1"
    assert quickstart =~ "automatic orchestration disabled"
    refute quickstart =~ "sk-"
  end

  test "documented project command aliases exist" do
    aliases = Mix.Project.config()[:aliases]

    for command <- [
          :setup,
          :"ecto.setup",
          :"ecto.reset",
          :"assets.setup",
          :"assets.build",
          :"assets.deploy",
          :test
        ] do
      assert Keyword.has_key?(aliases, command), "missing mix #{command} alias"
    end
  end

  test "installer has valid shell syntax and keeps input out of generated Elixir" do
    assert {"", 0} = System.cmd("bash", ["-n", "install.sh"], stderr_to_stdout: true)

    installer = File.read!("install.sh")

    assert installer =~ "APP_HOST=$DOMAIN"
    assert installer =~ "LIVE_VIEW_SALT=$LIVE_VIEW_SALT"
    assert installer =~ "System.fetch_env!(\"CYMPHO_INSTALL_ADMIN_EMAIL\")"
    assert installer =~ "chmod 600 \"$ENV_FILE\""
    refute installer =~ "APP_HOST=\"https://$DOMAIN\""
    refute installer =~ "email: \"$ADMIN_EMAIL\""
    refute installer =~ "password: \"$ADMIN_PASSWORD\""
  end

  test "release deploy generates isolated origins and durable upload storage" do
    assert {"", 0} = System.cmd("bash", ["-n", "deploy.sh"], stderr_to_stdout: true)

    deploy = File.read!("deploy.sh")
    service = File.read!("deploy/cympho.service")

    assert deploy =~ "PREVIEW_HOST=${PREVIEW_DOMAIN}"
    assert deploy =~ "CYMPHO_UPLOADS_DIR=${UPLOADS_DIR}"
    assert deploy =~ "CYMPHO_IMPORT_SPOOL_DIR=${IMPORT_SPOOL_DIR}"
    assert deploy =~ "UPLOADS_DIR=\"${DEPLOY_ROOT}/data/uploads\""
    assert deploy =~ "IMPORT_SPOOL_DIR=\"${DEPLOY_ROOT}/data/import-transfers\""
    assert deploy =~ "install -d -m 0750 -o ${APP_USER} -g ${APP_USER} ${UPLOADS_DIR}"
    assert deploy =~ "install -d -m 0700 -o ${APP_USER} -g ${APP_USER} ${IMPORT_SPOOL_DIR}"
    assert deploy =~ "reconcile_env_key PREVIEW_HOST ${PREVIEW_DOMAIN}"
    assert deploy =~ "reconcile_env_key CYMPHO_UPLOADS_DIR ${UPLOADS_DIR}"
    assert deploy =~ "reconcile_env_key CYMPHO_IMPORT_SPOOL_DIR ${IMPORT_SPOOL_DIR}"
    refute deploy =~ "CYMPHO_MAX_LOCAL_AGENT_RUNS="
    refute deploy =~ "CYMPHO_LOCAL_AGENT_MEMORY_RESERVE_MB="
    assert deploy =~ "preview_site_avail=/etc/nginx/sites-available/${PREVIEW_DOMAIN}"
    assert deploy =~ "cympho-preview-access.log"
    refute deploy =~ "cp \"\$site_avail\" \"\$tmp\""
    assert deploy =~ "grep -Fq \"DNS:${PREVIEW_DOMAIN}\""
    assert deploy =~ "certbot_args=\"--cert-name ${DOMAIN} --expand\""
    assert deploy =~ ~S(certbot --nginx \$certbot_args -d ${DOMAIN} -d ${PREVIEW_DOMAIN})
    refute service =~ "After=docker.service"
  end

  test "operator and security docs preserve the credential boundary" do
    combined =
      ["docs/OPERATIONS.md", "docs/OBSERVABILITY.md", "SECURITY.md"]
      |> Enum.map_join("\n", &File.read!/1)

    assert combined =~ "Never commit real credentials"
    assert combined =~ "does **not** export"
    assert combined =~ "review mode"
    refute combined =~ ~r/sk-[A-Za-z0-9]{12,}/
  end

  test "operator docs distinguish total, local-process, and memory admission" do
    operations = File.read!("docs/OPERATIONS.md")
    quickstart = File.read!("docs/QUICKSTART.md")
    readme = File.read!("README.md")

    assert operations =~ "CYMPHO_MAX_LOCAL_AGENT_RUNS"
    assert operations =~ "CYMPHO_LOCAL_AGENT_MEMORY_RESERVE_MB"

    assert operations =~ "host/cgroup memory"
    assert operations =~ "not a per-process memory reservation"
    assert operations =~ "disabled memory gate"
    assert operations =~ "not cgroup-aware"
    assert operations =~ "Debian/Ubuntu `apt` path"
    assert operations =~ ~r/not a\s+separately running Cympho service/
    assert quickstart =~ "named resource profile"
    assert readme =~ "local CLI processes"
    assert readme =~ "gateway work"
  end
end
