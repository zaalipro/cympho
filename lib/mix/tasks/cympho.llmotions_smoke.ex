defmodule Mix.Tasks.Cympho.LlmotionsSmoke do
  @shortdoc "Create an LLMotions-backed autonomous smoke company"

  @moduledoc """
  Creates a focused real-world smoke scenario for watching CEO, CTO,
  engineering, and QA handoffs with LLMotions executive agents.

  ## Usage

      LLMOTIONS_API_KEY=... mix cympho.llmotions_smoke --yes

  ## Options

    * `--company-name` - Company name (default: timestamped LLMotions Smoke)
    * `--issue-prefix` - Project/issue prefix (default: LMS)
    * `--model` - Executive model: gemma-4-31b, gemini-3.5-flash-low,
      gemini-3.5-flash, or any compatible custom model (default: gemma-4-31b)
    * `--api-key-env` - Environment variable containing the API key
      (default: LLMOTIONS_API_KEY)
    * `--api-key` - Direct API key value. Prefer `--api-key-env` to avoid shell
      history exposure.
    * `--repo-cwd` - Repo path for repo-capable agents (default: current dir)
    * `--no-workspace` - Do not create a primary project workspace
    * `--no-secret` - Do not store the API key in Cympho Secrets
    * `--keep-seed-issues` - Leave blueprint seed issues active instead of
      cancelling them for a focused smoke run
    * `--no-focus` - Do not pin the generated issue for focused dispatch
    * `--yes` - Skip confirmation
  """

  use Mix.Task

  alias Cympho.Smoke.LLMotions

  @switches [
    company_name: :string,
    issue_prefix: :string,
    model: :string,
    api_key_env: :string,
    api_key: :string,
    repo_cwd: :string,
    no_workspace: :boolean,
    no_secret: :boolean,
    keep_seed_issues: :boolean,
    no_focus: :boolean,
    yes: :boolean
  ]

  @aliases [
    n: :company_name,
    p: :issue_prefix,
    m: :model,
    y: :yes
  ]

  @impl Mix.Task
  def run(args) do
    previous_log_level = Logger.level()
    Logger.configure(level: :warning)

    try do
      run_quietly(args)
    after
      Logger.configure(level: previous_log_level)
    end
  end

  defp run_quietly(args) do
    Mix.Task.run("app.start", [])

    {opts, _args, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    api_key_env = opts[:api_key_env] || LLMotions.secret_key()
    api_key = opts[:api_key] || System.get_env(api_key_env)
    model = opts[:model] || LLMotions.default_model()

    unless opts[:yes] do
      Mix.shell().info("""
      About to create an LLMotions smoke company:
        Endpoint:      #{LLMotions.endpoint()}
        Model:         #{model}
        API key env:   #{api_key_env}
        Secret status: #{if present?(api_key), do: "will store encrypted secret", else: "missing; preflight will show setup action"}
      """)

      unless Mix.shell().yes?("Proceed?") do
        Mix.shell().info("Aborted.")
        exit({:shutdown, 1})
      end
    end

    setup_opts = [
      company_name: opts[:company_name],
      issue_prefix: opts[:issue_prefix] || "LMS",
      model: model,
      api_key: api_key,
      store_secret?: opts[:no_secret] != true,
      create_workspace?: opts[:no_workspace] != true,
      repo_cwd: opts[:repo_cwd] || File.cwd!(),
      cancel_seed_issues?: opts[:keep_seed_issues] != true,
      focus?: opts[:no_focus] != true
    ]

    case LLMotions.setup(setup_opts) do
      {:ok, report} ->
        Mix.shell().info(report.text)

      {:error, reason} ->
        Mix.shell().error("LLMotions smoke setup failed: #{inspect(reason)}")
        Mix.raise("LLMotions smoke setup failed")
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
