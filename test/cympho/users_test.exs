defmodule Cympho.UsersTest do
  use Cympho.DataCase, async: true

  alias Cympho.Users
  alias Cympho.Users.User

  setup do
    {:ok, user} =
      Users.create_user(%{
        email: "test@example.com",
        name: "Test User"
      })

    %{user: user}
  end

  describe "list_users/0" do
    test "returns all users", %{user: user} do
      users = Users.list_users()
      assert length(users) >= 1
      assert Enum.any?(users, fn u -> u.id == user.id end)
    end
  end

  describe "get_user!/1" do
    test "returns the user with given id", %{user: user} do
      found = Users.get_user!(user.id)
      assert found.id == user.id
      assert found.email == user.email
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Users.get_user!("00000000-0000-0000-0000-000000000000")
      end
    end
  end

  describe "get_user/1" do
    test "returns {:ok, user} for valid id", %{user: user} do
      assert {:ok, found} = Users.get_user(user.id)
      assert found.id == user.id
    end

    test "returns {:error, :not_found} for non-existent id" do
      assert {:error, :not_found} = Users.get_user("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "get_user_by_email/1" do
    test "returns {:ok, user} for valid email", %{user: user} do
      assert {:ok, found} = Users.get_user_by_email(user.email)
      assert found.id == user.id
    end

    test "returns {:error, :not_found} for non-existent email" do
      assert {:error, :not_found} = Users.get_user_by_email("nonexistent@example.com")
    end
  end

  describe "get_user_by_telegram_chat_id/1" do
    test "returns {:error, :not_found} when no user has the chat_id" do
      assert {:error, :not_found} = Users.get_user_by_telegram_chat_id("123456789")
    end

    test "returns {:ok, user} when user has the telegram_chat_id", %{user: user} do
      {:ok, updated} = Users.update_user(user, %{telegram_chat_id: "123456789"})
      assert {:ok, found} = Users.get_user_by_telegram_chat_id("123456789")
      assert found.id == updated.id
    end
  end

  describe "create_user/1" do
    test "creates user with valid data" do
      attrs = %{email: "new@example.com", name: "New User"}
      assert {:ok, %User{} = user} = Users.create_user(attrs)
      assert user.email == "new@example.com"
      assert user.name == "New User"
    end

    test "creates user with notification preferences" do
      attrs = %{
        email: "notify@example.com",
        name: "Notify User",
        telegram_enabled: true,
        telegram_chat_id: "12345",
        email_enabled: true,
        webhook_enabled: false
      }

      assert {:ok, %User{} = user} = Users.create_user(attrs)
      assert user.telegram_enabled == true
      assert user.telegram_chat_id == "12345"
      assert user.email_enabled == true
      assert user.webhook_enabled == false
    end

    test "returns error changeset for invalid data" do
      attrs = %{email: "", name: ""}
      assert {:error, %Ecto.Changeset{}} = Users.create_user(attrs)
    end

    test "returns error changeset for invalid email format" do
      attrs = %{email: "notanemail", name: "Bad Email User"}
      assert {:error, %Ecto.Changeset{}} = Users.create_user(attrs)
    end
  end

  describe "update_user/2" do
    test "updates user with valid data", %{user: user} do
      attrs = %{name: "Updated Name"}
      assert {:ok, updated} = Users.update_user(user, attrs)
      assert updated.name == "Updated Name"
    end

    test "updates telegram settings", %{user: user} do
      attrs = %{telegram_chat_id: "999999999", telegram_enabled: true}
      assert {:ok, updated} = Users.update_user(user, attrs)
      assert updated.telegram_chat_id == "999999999"
      assert updated.telegram_enabled == true
    end

    test "returns error changeset for invalid email", %{user: user} do
      attrs = %{email: "invalid"}
      assert {:error, %Ecto.Changeset{}} = Users.update_user(user, attrs)
    end
  end

  describe "update_notification_prefs/2" do
    test "enables telegram notifications", %{user: user} do
      attrs = %{telegram_enabled: true, telegram_chat_id: "5555555"}
      assert {:ok, updated} = Users.update_notification_prefs(user, attrs)
      assert updated.telegram_enabled == true
      assert updated.telegram_chat_id == "5555555"
    end

    test "disables email notifications", %{user: user} do
      attrs = %{email_enabled: false}
      assert {:ok, updated} = Users.update_notification_prefs(user, attrs)
      assert updated.email_enabled == false
    end

    test "sets webhook URL", %{user: user} do
      attrs = %{webhook_enabled: true, webhook_url: "https://example.com/webhook"}
      assert {:ok, updated} = Users.update_notification_prefs(user, attrs)
      assert updated.webhook_enabled == true
      assert updated.webhook_url == "https://example.com/webhook"
    end

    test "rejects invalid webhook URL", %{user: user} do
      attrs = %{webhook_url: "not-a-valid-url"}
      assert {:error, %Ecto.Changeset{}} = Users.update_notification_prefs(user, attrs)
    end
  end

  describe "delete_user/1" do
    test "deletes the user", %{user: user} do
      assert :ok = Users.delete_user(user)

      assert_raise Ecto.NoResultsError, fn ->
        Users.get_user!(user.id)
      end
    end
  end

  describe "change_user/2" do
    test "returns a changeset for the user" do
      user = %User{email: "test@example.com", name: "Test"}
      changeset = Users.change_user(user, %{})
      assert %Ecto.Changeset{} = changeset
    end
  end
end
