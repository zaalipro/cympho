defmodule Cympho.Repo do
  use Ecto.Repo,
    otp_app: :cympho,
    adapter: Ecto.Adapters.Postgres
end
