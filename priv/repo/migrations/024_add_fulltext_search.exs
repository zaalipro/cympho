defmodule Cympho.Repo.Migrations.AddFulltextSearch do
  use Ecto.Migration

  def up do
    # Add tsvector columns
    alter table(:issues) do
      add :search_vector, :map, default: nil
    end

    alter table(:comments) do
      add :search_vector, :map, default: nil
    end

    execute """
    ALTER TABLE issues ALTER COLUMN search_vector TYPE tsvector USING to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, ''));
    """

    execute """
    ALTER TABLE comments ALTER COLUMN search_vector TYPE tsvector USING to_tsvector('english', coalesce(body, ''));
    """

    # GIN indexes for fast tsvector lookups
    execute "CREATE INDEX issues_search_vector_idx ON issues USING GIN (search_vector);"
    execute "CREATE INDEX comments_search_vector_idx ON comments USING GIN (search_vector);"

    # Function to update issue search vector
    execute """
    CREATE OR REPLACE FUNCTION issues_search_vector_update() RETURNS trigger AS $$
    BEGIN
      NEW.search_vector :=
        setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(NEW.description, '')), 'B');
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Function to update comment search vector
    execute """
    CREATE OR REPLACE FUNCTION comments_search_vector_update() RETURNS trigger AS $$
    BEGIN
      NEW.search_vector :=
        setweight(to_tsvector('english', coalesce(NEW.body, '')), 'C');
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Triggers to keep vectors in sync
    execute """
    CREATE TRIGGER issues_search_vector_trigger
    BEFORE INSERT OR UPDATE OF title, description ON issues
    FOR EACH ROW EXECUTE FUNCTION issues_search_vector_update();
    """

    execute """
    CREATE TRIGGER comments_search_vector_trigger
    BEFORE INSERT OR UPDATE OF body ON comments
    FOR EACH ROW EXECUTE FUNCTION comments_search_vector_update();
    """

    # Backfill existing rows
    execute "UPDATE issues SET search_vector = setweight(to_tsvector('english', coalesce(title, '')), 'A') || setweight(to_tsvector('english', coalesce(description, '')), 'B');"
    execute "UPDATE comments SET search_vector = to_tsvector('english', coalesce(body, ''));"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS comments_search_vector_trigger ON comments;"
    execute "DROP TRIGGER IF EXISTS issues_search_vector_trigger ON issues;"
    execute "DROP FUNCTION IF EXISTS comments_search_vector_update();"
    execute "DROP FUNCTION IF EXISTS issues_search_vector_update();"
    execute "DROP INDEX IF EXISTS comments_search_vector_idx;"
    execute "DROP INDEX IF EXISTS issues_search_vector_idx;"

    alter table(:comments) do
      remove :search_vector
    end

    alter table(:issues) do
      remove :search_vector
    end
  end
end
