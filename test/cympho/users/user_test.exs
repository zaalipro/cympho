defmodule Cympho.Users.UserTest do
  use ExUnit.Case, async: true

  alias Cympho.Users.User
  alias Cympho.DataCase

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{email: "test@example.com", name: "Test User"}
      changeset = User.changeset(%User{}, attrs)
      assert changeset.valid?
    end

    test "invalid changeset when email is missing" do
      attrs = %{name: "Test User"}
      changeset = User.changeset(%User{}, attrs)
      refute changeset.valid?
      assert Keyword.get(changeset.errors, :email)
    end

    test "invalid changeset when name is missing" do
      attrs = %{email: "test@example.com"}
      changeset = User.changeset(%User{}, attrs)
      refute changeset.valid?
      assert Keyword.get(changeset.errors, :name)
    end

    test "invalid changeset when email format is invalid" do
      attrs = %{email: "notanemail", name: "Test User"}
      changeset = User.changeset(%User{}, attrs)
      refute changeset.valid?
      assert Keyword.get(changeset.errors, :email)
    end

    test "valid changeset with all notification fields" do
      attrs = %{
        email: "test@example.com",
        name: "Test User",
        telegram_chat_id: "123456789",
        telegram_enabled: true,
        email_enabled: true,
        webhook_enabled: true,
        webhook_url: "https://example.com/webhook"
      }

      changeset = User.changeset(%User{}, attrs)
      assert changeset.valid?
    end

    test "valid changeset with empty webhook_url" do
      attrs = %{
        email: "test@example.com",
        name: "Test User",
        webhook_url: ""
      }

      changeset = User.changeset(%User{}, attrs)
      assert changeset.valid?
    end

    test "invalid changeset when webhook_url is malformed" do
      attrs = %{
        email: "test@example.com",
        name: "Test User",
        webhook_url: "not-a-url"
      }

      changeset = User.changeset(%User{}, attrs)
      refute changeset.valid?
      assert Keyword.get(changeset.errors, :webhook_url)
    end

    test "invalid changeset when email exceeds max length" do
      long_email = String.pad_leading("test@example.com", 300, "a")
      attrs = %{email: long_email, name: "Test User"}
      changeset = User.changeset(%User{}, attrs)
      refute changeset.valid?
      assert Keyword.get(changeset.errors, :email)
    end
  end
end
