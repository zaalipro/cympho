defmodule Cympho.Onboarding.Readiness do
  @moduledoc """
  The three checks setup runs before a new company may launch.

    * Installed: the runtime's program is found on this server.
    * Signed in: the program answers a one-line test prompt.
    * Can be priced: the spending limit can put a cost on every run, because
      the runtime reports its cost or prices were entered for its model. This
      is the hard stop's own rule (`Cympho.Finances.Pricing`).

  The first two touch the server, so they go through the prober set by
  `config :cympho, :readiness_prober` (default `Readiness.Shell`) and run only
  when the owner asks, never on mount. A result is kept for the runtime it was
  taken on (`key/2`): another program or model needs a new check. Pricing is
  decided from the form every time, so typing a price needs no new check.
  """

  require Logger

  alias Cympho.Adapters.Registry
  alias Cympho.Finances.Pricing

  @doc "True when `program` is found on this server."
  @callback installed?(program :: String.t()) :: boolean()

  @doc "True when `program` answers a one-line test prompt."
  @callback answers?(adapter :: String.t(), program :: String.t(), model :: String.t() | nil) ::
              boolean()

  @probed ~w(claude_code codex)

  @doc """
  Runs the two server checks for `adapter` with the onboarding runtime
  `config` (`"command"`, `"model"`, `"pricing"`) and returns the result to keep
  in the draft. A runtime setup does not offer is never probed.
  """
  @spec check(String.t(), map()) :: map()
  def check(adapter, config) when adapter in @probed do
    prober = prober()
    program = program(adapter, config)
    installed = prober.installed?(program)
    signed_in = installed and prober.answers?(adapter, program, present(config["model"]))

    Logger.info("onboarding readiness checked",
      component: "onboarding",
      adapter: adapter,
      installed: installed,
      signed_in: signed_in
    )

    result(adapter, config, installed, signed_in)
  end

  def check(adapter, config), do: result(adapter, config, false, false)

  defp result(adapter, config, installed, signed_in) do
    %{"checked" => key(adapter, config), "installed" => installed, "signed_in" => signed_in}
  end

  @doc "The runtime a result belongs to: provider, command and model."
  @spec key(String.t(), map()) :: String.t()
  def key(adapter, config) do
    Enum.join([adapter, present(config["command"]) || "", present(config["model"]) || ""], "|")
  end

  @doc "True when `result` was taken on this runtime."
  def current?(%{"checked" => checked}, adapter, config), do: checked == key(adapter, config)
  def current?(_result, _adapter, _config), do: false

  @doc "True when every check passes for this runtime; Continue and launch need it."
  def ready?(%{"installed" => true, "signed_in" => true} = result, adapter, config) do
    current?(result, adapter, config) and priceable?(adapter, config)
  end

  def ready?(_result, _adapter, _config), do: false

  @doc "True when the spending limit can price every run of this runtime."
  @spec priceable?(String.t(), map()) :: boolean()
  def priceable?(adapter, config) do
    case module(adapter) do
      {:ok, module} ->
        Pricing.priceable?(module, config, Pricing.snapshot(config, adapter, config["model"]))

      :error ->
        false
    end
  end

  @doc """
  The program a run starts: Claude Code's configured command (the adapter's
  own order of sources), always `codex` for Codex.
  """
  def program("claude_code", config) do
    present(config["command"]) || Application.get_env(:cympho, :claude_code_command) ||
      present(System.get_env("CYMPHO_CLAUDE_COMMAND")) || "claude"
  end

  def program("codex", _config), do: "codex"
  def program(_adapter, _config), do: nil

  defp module(adapter) do
    Registry.lookup(String.to_existing_atom(adapter))
  rescue
    ArgumentError -> :error
  end

  defp prober, do: Application.get_env(:cympho, :readiness_prober, __MODULE__.Shell)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defmodule Shell do
    @moduledoc """
    Runs the probes on this server the way agent runs start a CLI: `bash -lc`,
    `$HOME/.cld` sourced first, a scrubbed environment, then the program. The
    signed-in probe sends one short prompt (a few tokens) and gives up after
    90 seconds.
    """
    @behaviour Cympho.Onboarding.Readiness

    @prompt "Reply with the single word: ready"
    @find_timeout_ms 5_000
    @answer_timeout_ms 90_000

    @impl true
    def installed?(program) do
      match?(
        {_output, 0},
        run("command -v -- #{shell_quote(program)} >/dev/null 2>&1", [], @find_timeout_ms)
      )
    end

    @impl true
    def answers?("claude_code", program, model) do
      env = [
        {"ANTHROPIC_MODEL", model},
        {"ANTHROPIC_API_KEY", Application.get_env(:cympho, :anthropic_api_key)}
      ]

      script =
        "exec #{shell_quote(program)} -p --bare --output-format json #{shell_quote(@prompt)}"

      case run(script, env, @answer_timeout_ms) do
        {output, 0} -> not match?({:ok, %{"is_error" => true}}, last_json(output))
        _failed -> false
      end
    end

    def answers?("codex", program, model) do
      env = [
        {"OPENAI_API_KEY",
         Application.get_env(:cympho, :openai_api_key) || System.get_env("OPENAI_API_KEY")}
      ]

      model_args = if model, do: " --model #{shell_quote(model)}", else: ""

      script =
        "exec #{shell_quote(program)} exec --skip-git-repo-check --sandbox read-only --color never" <>
          model_args <> " #{shell_quote(@prompt)}"

      match?({_output, 0}, run(script, env, @answer_timeout_ms))
    end

    def answers?(_adapter, _program, _model), do: false

    defp run(script, env, timeout) do
      env =
        Cympho.Adapters.ProcessAdapter.health_check_env()
        |> Map.new()
        |> Map.merge(Map.new(env, fn {key, value} -> {key, present(value)} end))
        |> Enum.to_list()

      task =
        Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
          System.cmd("bash", ["-lc", ~s(source "$HOME/.cld" 2>/dev/null || true; ) <> script],
            cd: System.tmp_dir!(),
            env: env,
            stderr_to_stdout: true
          )
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _timeout_or_crash -> :failed
      end
    end

    defp last_json(output) do
      output |> String.split("\n", trim: true) |> List.last("") |> Jason.decode()
    end

    defp shell_quote(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"

    defp present(value) when is_binary(value) and value != "", do: value
    defp present(_value), do: nil
  end

  defmodule Fake do
    @moduledoc """
    The test prober (`config/test.exs`). It runs nothing and answers from the
    program name: "missing" is not installed, "refused" does not answer. Each
    call is reported to the calling process and its `$callers`, so a test can
    prove when a check ran.
    """
    @behaviour Cympho.Onboarding.Readiness

    @impl true
    def installed?(program) do
      notify({:readiness_prober, :installed?, program})
      not String.contains?(program, "missing")
    end

    @impl true
    def answers?(adapter, program, _model) do
      notify({:readiness_prober, :answers?, adapter})
      not String.contains?(program, "refused")
    end

    defp notify(message) do
      Enum.each([self() | Process.get(:"$callers", [])], &send(&1, message))
    end
  end
end
