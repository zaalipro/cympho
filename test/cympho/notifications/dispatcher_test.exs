defmodule Cympho.Notifications.DispatcherTest do
  use Cympho.DataCase, async: false

  alias Cympho.Notifications.Dispatcher
  alias Cympho.Notifications.Message
  alias Cympho.Users

  describe "dispatch/1" do
    test "returns error when user not found" do
      message = Message.new("Subject", "Body", "nonexistent-user-id")
      assert Dispatcher.dispatch(message) == {:error, :user_not_found}
    end

    test "email delivery uses the user's email when pref config is empty" do
      unique = System.unique_integer([:positive])

      {:ok, user} =
        Users.create_user(%{
          email: "notify-#{unique}@example.com",
          name: "Notify User #{unique}"
        })

      Users.ensure_default_prefs(user.id)
      Dispatcher.invalidate_cache(user.id)

      assert :ok = Dispatcher.dispatch(Message.new("Hello", "Body", user.id))
    end
  end

  describe "cache_preference/1" do
    test "replaces an existing preference by id instead of dropping it" do
      unique = System.unique_integer([:positive])

      {:ok, user} =
        Users.create_user(%{
          email: "cache-#{unique}@example.com",
          name: "Cache User #{unique}"
        })

      Users.ensure_default_prefs(user.id)
      Dispatcher.warm_cache()

      email_pref =
        user.id
        |> Users.list_notification_prefs()
        |> Enum.find(&(&1.channel_type == "email"))

      {:ok, updated} =
        Users.upsert_notification_pref(user.id, "email", %{
          enabled: true,
          config: %{"email" => "replaced-#{unique}@example.com"}
        })

      Dispatcher.warm_cache()

      user_id = user.id
      [{^user_id, prefs}] = :ets.lookup(:notification_preferences_cache, user_id)
      cached = Enum.filter(prefs, &(&1.id == email_pref.id))

      assert length(cached) == 1
      assert hd(cached).config["email"] == "replaced-#{unique}@example.com"
      assert hd(cached).id == updated.id
    end
  end
end
