defmodule Cympho.Notifications.Dispatcher do
  @moduledoc """
  Dispatches notifications to enabled channels for a user.

  Uses an ETS cache (:notification_preferences_cache) to avoid repeated DB reads.
  Cache is populated on first lookup (cache-aside pattern) and can be warmed
  via warm_cache/0 or invalidated via invalidate_cache/1.
  """

  import Ecto.Query
  alias Cympho.Notifications.{Channel, EmailChannel, Message, TelegramChannel, WebhookChannel}
  alias Cympho.Notifications.NotificationPreference
  alias Cympho.Users

  @cache_table :notification_preferences_cache
  @channels %{
    email: EmailChannel,
    telegram: TelegramChannel,
    webhook: WebhookChannel
  }

  # --- Cache setup ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    table_opts = [:set, :named_table, :public, read_concurrency: true, write_concurrency: true]
    :ets.new(@cache_table, table_opts)
    warm_cache()
    {:ok, %{}}
  end

  # --- Client API ---

  @doc """
  Dispatch a notification to all enabled channels for a user.
  Returns :ok if all channels succeed, {:partial_failure, results} otherwise.
  """
  def dispatch(%Message{} = message) do
    case Users.get_user(message.user_id) do
      {:ok, user} ->
        dispatch_to_user(message, user)

      {:error, :not_found} ->
        {:error, :user_not_found}
    end
  end

  @doc """
  Dispatch a notification asynchronously using Task.Supervisor.
  """
  def dispatch_async(%Message{} = message, supervisor \\ Cympho.TaskSupervisor) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      dispatch(message)
    end)
  end

  @doc """
  Warm the ETS cache by loading all notification preferences from the DB.
  """
  def warm_cache do
    preferences = Cympho.Repo.all(NotificationPreference)
    Enum.each(preferences, &cache_preference/1)
    :ok
  end

  @doc """
  Invalidate the cache entry for a specific user, forcing the next dispatch
  to reload from the DB.
  """
  def invalidate_cache(user_id) do
    :ets.delete(@cache_table, user_id)
    :ok
  end

  # --- Server ---

  @impl true
  def handle_info(:warm_cache, state) do
    warm_cache()
    {:noreply, state}
  end

  # --- Internal ---

  defp dispatch_to_user(%Message{} = message, user) do
    channel_configs = lookup_preferences(user.id) |> Enum.filter(& &1.enabled)

    results =
      Enum.map(channel_configs, fn pref ->
        type = String.to_existing_atom(pref.channel_type)
        channel_module = Map.fetch!(@channels, type)
        result = deliver_via(channel_module, message, pref.config)
        {type, result}
      end)

    failed = Enum.filter(results, fn {_type, result} -> result != :ok end)

    if Enum.empty?(failed) do
      :ok
    else
      {:partial_failure, results}
    end
  end

  defp deliver_via(channel_module, message, config) do
    if channel_module.available?(config) do
      channel_module.deliver(message, config)
    else
      {:error, :channel_unavailable}
    end
  end

  # Cache-aside pattern: check ETS first, fall back to DB
  defp lookup_preferences(user_id) do
    case :ets.lookup(@cache_table, user_id) do
      [{^user_id, prefs}] when is_list(prefs) ->
        prefs

      [] ->
        prefs = load_from_db(user_id)
        :ets.insert(@cache_table, {user_id, prefs})
        prefs
    end
  end

  defp load_from_db(user_id) do
    Cympho.Repo.all(
      from p in NotificationPreference,
        where: p.user_id == ^user_id and p.enabled == true
    )
  end

  defp cache_preference(%NotificationPreference{} = pref) do
    existing = :ets.lookup(@cache_table, pref.user_id) |> List.wrap() |> Enum.flat_map(fn {_, ps} -> ps end)
    new_prefs = Enum.reject(existing ++ [pref], fn p -> p.id == pref.id end)
    :ets.insert(@cache_table, {pref.user_id, new_prefs})
  end
end