defmodule CymphoWeb.CompanyChannelRateLimitTest do
  use CymphoWeb.ChannelCase

  describe "per-socket message rate limit" do
    test "allows messages within rate limit" do
      company_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      {:ok, _, socket} =
        subscribe_and_join(socket, CymphoWeb.CompanyChannel, "company:#{company_id}")

      for _ <- 1..5, do: push(socket, "some_event", %{})

      ref = push(socket, "ping", %{})
      assert_reply ref, :ok, %{pong: true}
    end

    test "rate limits when exceeding 10 events/sec" do
      company_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      {:ok, _, socket} =
        subscribe_and_join(socket, CymphoWeb.CompanyChannel, "company:#{company_id}")

      for _ <- 1..10, do: push(socket, "ping", %{})

      ref = push(socket, "ping", %{})
      assert_reply ref, :error, %{reason: "rate_limited"}
    end
  end

  describe "heartbeat throttling" do
    test "allows first heartbeat" do
      company_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      {:ok, _, socket} =
        subscribe_and_join(socket, CymphoWeb.CompanyChannel, "company:#{company_id}")

      ref = push(socket, "heartbeat", %{status: "alive"})
      assert_reply ref, :ok, _
    end

    test "rejects rapid heartbeat within 1 second" do
      company_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      {:ok, _, socket} =
        subscribe_and_join(socket, CymphoWeb.CompanyChannel, "company:#{company_id}")

      ref = push(socket, "heartbeat", %{status: "alive"})
      assert_reply ref, :ok, _

      ref = push(socket, "heartbeat", %{status: "alive"})
      assert_reply ref, :error, %{reason: "rate_limited"}
    end
  end
end
