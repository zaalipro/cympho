defmodule Cympho.Release do
  @moduledoc """
  Release tasks that run without Mix in a built release.

  Invoke from the deployed release, e.g.:

      bin/cympho eval "Cympho.Release.migrate"
  """

  @app :cympho

  # Migrations run against a database the previous release is still serving, so
  # `with_repo/3` would otherwise open a second full-sized pool (POOL_SIZE, 25
  # in production) alongside the live one. On a Postgres cluster shared with
  # other applications that is enough to exhaust max_connections and fail the
  # deploy. Migrations are single-connection work; two is ample.
  @migration_pool_size 2

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true),
          pool_size: @migration_pool_size
        )
    end
  end

  def rollback(repo, version) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version),
        pool_size: @migration_pool_size
      )
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
