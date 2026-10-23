defmodule Cympho.Notifications.Dispatcher do
  @moduledoc """
  Dispatches notifications to enabled channels for a user.

  Uses an ETS cache (:notification_preferences_cache) to avoid repeated DB reads.
  Cache is populated on first lookup (cache-aside pattern) and can be invalidated
  via invalidate_cache/1. warm_cache/0 remains available for explicit callers.

  Channel delivery runs concurrently via Task.Supervisor.async_nolink/2
  for fan-out parallelism across enabled channels.
  """

  use GenServer

  import Ecto.Query, warn: false
  require Logger

  alias Cympho.Notifications.{EmailChannel, Message, TelegramChannel, WebhookChannel}
  alias Cympho.Notifications.NotificationPreference
  alias Cympho.Users

  @cache_table :notification_preferences_cache
  @channels %{
    email: EmailChannel,
    telegram: TelegramChannel,
    webhook: WebhookChannel
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table_opts = [:set, :named_table, :public, read_concurrency: true, write_concurrency: true]
    :ets.new(@cache_table, table_opts)
    {:ok, %{}}
  end

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
  Dispatch a notification asynchronously, fire-and-forget. The spawned task
  is supervised but no result message is sent back to the caller, so this is
  safe to invoke from long-lived processes (e.g. GenServers).
  """
  def dispatch_async(%Message{} = message, supervisor \\ Cympho.TaskSupervisor) do
    Task.Supervisor.start_child(supervisor, fn ->
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

  @impl true
  def handle_info(:warm_cache, state) do
    warm_cache()
    {:noreply, state}
  end

  defp dispatch_to_user(%Message{} = message, user) do
    event = resolve_event(message)

    channel_configs =
      lookup_preferences(user.id)
      |> Enum.filter(& &1.enabled)
      |> Enum.filter(&event_allowed?(&1, event))

    tasks =
      Enum.flat_map(channel_configs, fn pref ->
        case channel_for(pref.channel_type) do
          {:ok, type, channel_module} ->
            task =
              Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
                {type, deliver_via(channel_module, message, pref.config, user)}
              end)

            [{type, task}]

          :error ->
            Logger.warning(
              "Skipping unsupported notification channel #{inspect(pref.channel_type)}",
              user_id: user.id
            )

            []
        end
      end)

    results =
      Enum.map(tasks, fn {type, task} ->
        case Task.yield(task, 5_000) || Task.shutdown(task, 1_000) do
          {:ok, result} -> result
          nil -> {type, {:error, :timeout}}
          {:exit, reason} -> {type, {:error, {:exit, reason}}}
        end
      end)

    failed = Enum.filter(results, fn {_type, result} -> result != :ok end)

    if Enum.empty?(failed) do
      :ok
    else
      {:partial_failure, results}
    end
  end

  # Per-event channel preferences live in pref.config["events"]; gate delivery on
  # the message's event (event_type, else metadata :type).
  defp resolve_event(%Message{event_type: type}) when is_binary(type) and type != "", do: type
  defp resolve_event(%Message{metadata: %{type: type}}) when is_binary(type), do: type
  defp resolve_event(%Message{metadata: %{"type" => type}}) when is_binary(type), do: type
  defp resolve_event(_message), do: nil

  @doc """
  Whether a channel preference carries `event`: the saved choice in
  `config["events"]`, else the event's default (`Users.default_event_config/0`:
  the opt-in alert events are off), else on. A message without an event is
  always delivered.
  """
  def event_allowed?(_pref, nil), do: true

  def event_allowed?(pref, event) do
    (pref.config || %{})
    |> Map.get("events", %{})
    |> Map.get(event, Map.get(Users.default_event_config(), event, true))
  end

  @doc """
  Sends an opt-in alert `event` to the members of `company_id` who chose it on
  an enabled channel. `build` returns `{subject, body, metadata}`; it runs only
  when someone chose the event, so hot paths pay one query otherwise.
  """
  def notify_company_opt_in(company_id, event, build)
      when is_binary(company_id) and is_binary(event) and is_function(build, 0) do
    case opted_in_user_ids(company_id, event) do
      [] ->
        :ok

      user_ids ->
        {subject, body, metadata} = build.()
        metadata = Map.put(metadata, :type, event)
        Enum.each(user_ids, &dispatch_async(Message.new(subject, body, &1, metadata)))
    end
  end

  def notify_company_opt_in(_company_id, _event, _build), do: :ok

  defp opted_in_user_ids(company_id, event) do
    Cympho.Repo.all(
      from p in NotificationPreference,
        join: m in Cympho.Companies.CompanyMembership,
        on: m.user_id == p.user_id,
        where:
          m.company_id == ^company_id and p.enabled == true and
            fragment("(?->'events'->>?) = 'true'", p.config, ^event),
        distinct: true,
        select: p.user_id
    )
  end

  defp channel_for(channel_type) when is_binary(channel_type) do
    case Enum.find(@channels, fn {type, _module} -> Atom.to_string(type) == channel_type end) do
      {type, channel_module} -> {:ok, type, channel_module}
      nil -> :error
    end
  end

  defp channel_for(_channel_type), do: :error

  defp deliver_via(EmailChannel, message, config, user) do
    config =
      (config || %{})
      |> Map.put("email", user.email)
      |> Map.put(:email, user.email)

    do_deliver(EmailChannel, message, config)
  end

  defp deliver_via(channel_module, message, config, _user) do
    do_deliver(channel_module, message, config)
  end

  defp do_deliver(channel_module, message, config) do
    if channel_module.available?(config) do
      channel_module.deliver(message, config)
    else
      {:error, :channel_unavailable}
    end
  end

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
    existing =
      :ets.lookup(@cache_table, pref.user_id)
      |> List.wrap()
      |> Enum.flat_map(fn {_, ps} -> ps end)

    new_prefs = Enum.reject(existing, &(&1.id == pref.id)) ++ [pref]
    :ets.insert(@cache_table, {pref.user_id, new_prefs})
  end
end
