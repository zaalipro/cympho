defmodule Cympho.Repo.Migrations.MakeIssueDescriptionNullable do
  use Ecto.Migration

  def up do
    execute "DROP TRIGGER IF EXISTS issues_search_vector_trigger ON issues"
    execute "DROP FUNCTION IF EXISTS issues_search_vector_update()"

    alter table(:issues) do
      modify :description, :text, null: true
    end

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

    execute """
    CREATE TRIGGER issues_search_vector_trigger
    BEFORE INSERT OR UPDATE OF title, description ON issues
    FOR EACH ROW EXECUTE FUNCTION issues_search_vector_update();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS issues_search_vector_trigger ON issues"
    execute "DROP FUNCTION IF EXISTS issues_search_vector_update()"

    alter table(:issues) do
      modify :description, :text, null: false
    end

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

    execute """
    CREATE TRIGGER issues_search_vector_trigger
    BEFORE INSERT OR UPDATE OF title, description ON issues
    FOR EACH ROW EXECUTE FUNCTION issues_search_vector_update();
    """
  end
end
