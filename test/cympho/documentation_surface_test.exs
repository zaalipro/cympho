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

  test "operator and security docs preserve the credential boundary" do
    combined =
      ["docs/OPERATIONS.md", "docs/OBSERVABILITY.md", "SECURITY.md"]
      |> Enum.map_join("\n", &File.read!/1)

    assert combined =~ "Never commit real credentials"
    assert combined =~ "does **not** export"
    assert combined =~ "review mode"
    refute combined =~ ~r/sk-[A-Za-z0-9]{12,}/
  end
end
