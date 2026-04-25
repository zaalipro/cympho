defmodule Cympho.Repo.Migrations.AddSearchToAgentsProjectsGoals do
  use Ecto.Migration

  def up do
    # Add tsvector columns
    alter table(:agents) do
      add :search_vector, :tsvector, default: nil
    end

    alter table(:projects) do
      add :search_vector, :tsvector, default: nil
    end

    alter table(:goals) do
      add :search_vector, :tsvector, default: nil
    end

    # GIN indexes for fast tsvector lookups
    execute "CREATE INDEX agents_search_vector_idx ON agents USING GIN (search_vector);"
    execute "CREATE INDEX projects_search_vector_idx ON projects USING GIN (search_vector);"
    execute "CREATE INDEX goals_search_vector_idx ON goals USING GIN (search_vector);"

    # Function to update agent search vector
    execute """
    CREATE OR REPLACE FUNCTION agents_search_vector_update() RETURNS trigger AS $$
    BEGIN
      NEW.search_vector :=
        setweight(to_tsvector('english', coalesce(NEW.name, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(NEW.instructions, '')), 'B');
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Function to update project search vector
    execute """
    CREATE OR REPLACE FUNCTION projects_search_vector_update() RETURNS trigger AS $$
    BEGIN
      NEW.search_vector :=
        setweight(to_tsvector('english', coalesce(NEW.name, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(NEW.description, '')), 'B');
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Function to update goal search vector
    execute """
    CREATE OR REPLACE FUNCTION goals_search_vector_update() RETURNS trigger AS $$
    BEGIN
      NEW.search_vector :=
        setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(NEW.description, '')), 'B');
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Triggers to keep vectors in sync
    execute """
    CREATE TRIGGER agents_search_vector_trigger
    BEFORE INSERT OR UPDATE OF name, instructions ON agents
    FOR EACH ROW EXECUTE FUNCTION agents_search_vector_update();
    """

    execute """
    CREATE TRIGGER projects_search_vector_trigger
    BEFORE INSERT OR UPDATE OF name, description ON projects
    FOR EACH ROW EXECUTE FUNCTION projects_search_vector_update();
    """

    execute """
    CREATE TRIGGER goals_search_vector_trigger
    BEFORE INSERT OR UPDATE OF title, description ON goals
    FOR EACH ROW EXECUTE FUNCTION goals_search_vector_update();
    """

    # Backfill existing rows
    execute "UPDATE agents SET search_vector = setweight(to_tsvector('english', coalesce(name, '')), 'A') || setweight(to_tsvector('english', coalesce(instructions, '')), 'B');"
    execute "UPDATE projects SET search_vector = setweight(to_tsvector('english', coalesce(name, '')), 'A') || setweight(to_tsvector('english', coalesce(description, '')), 'B');"
    execute "UPDATE goals SET search_vector = setweight(to_tsvector('english', coalesce(title, '')), 'A') || setweight(to_tsvector('english', coalesce(description, '')), 'B');"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS goals_search_vector_trigger ON goals;"
    execute "DROP TRIGGER IF EXISTS projects_search_vector_trigger ON projects;"
    execute "DROP TRIGGER IF EXISTS agents_search_vector_trigger ON agents;"
    execute "DROP FUNCTION IF EXISTS goals_search_vector_update();"
    execute "DROP FUNCTION IF EXISTS projects_search_vector_update();"
    execute "DROP FUNCTION IF EXISTS agents_search_vector_update();"
    execute "DROP INDEX IF EXISTS goals_search_vector_idx;"
    execute "DROP INDEX IF EXISTS projects_search_vector_idx;"
    execute "DROP INDEX IF EXISTS agents_search_vector_idx;"

    alter table(:goals) do
      remove :search_vector
    end

    alter table(:projects) do
      remove :search_vector
    end

    alter table(:agents) do
      remove :search_vector
    end
  end
end
