defmodule Cympho.Workspaces.EnvironmentDriver do
  @moduledoc """
  Behaviour for remote environment (sandbox) providers.

  Drivers provision, execute work in, and tear down remote execution
  environments. G6 starts with a Fake driver that proves the lifecycle
  contract before Runtime wiring or paid providers land.

  Lifecycle:
    1. `acquire/2` — provision; requires a non-empty `company_id` in opts
    2. `execute/3` — run a command against the returned `provider_ref`
    3. `release/2` — tear down (idempotent)
    4. `cancel/2` — optional early cancel + cleanup
  """

  @type company_id :: binary()
  @type provider_ref :: binary()
  @type metadata :: map()

  @typedoc """
  Opaque-ish handle returned by acquire. Callers may pass the full handle or
  just `provider_ref` into execute/release/cancel.
  """
  @type handle :: %{
          required(:provider_ref) => provider_ref(),
          required(:company_id) => company_id(),
          optional(:provider) => atom() | String.t(),
          optional(:metadata) => metadata()
        }

  @type command :: term()
  @type result :: map()
  @type opts :: map()
  @type config :: map()

  @doc """
  Acquire a remote environment.

  `opts` must include a non-empty `:company_id` or `"company_id"`. Returns a
  handle with a reusable `provider_ref` and redacted metadata (secret-like
  keys must not appear in cleartext).
  """
  @callback acquire(opts(), config()) :: {:ok, handle()} | {:error, term()}

  @doc """
  Execute a command in a previously acquired environment.

  `handle` may be a full handle map or a bare `provider_ref` binary.
  Fails when the environment was never acquired or has been released.
  """
  @callback execute(handle() | provider_ref(), command(), opts()) ::
              {:ok, result()} | {:error, term()}

  @doc """
  Release an acquired environment.

  Idempotent: releasing an already-released or unknown ref returns `:ok`.
  """
  @callback release(handle() | provider_ref(), opts()) :: :ok | {:error, term()}

  @doc """
  Cancel in-flight work and release the environment when the provider supports it.
  """
  @callback cancel(handle() | provider_ref(), opts()) :: :ok | {:error, term()}

  @optional_callbacks [cancel: 2]
end
