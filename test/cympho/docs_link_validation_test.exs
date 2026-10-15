defmodule Cympho.DocsLinkValidationTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @target_docs ["README.md" | Path.wildcard(Path.join([@repo_root, "docs", "*.md"]))]

  describe "documentation validation" do
    test "all internal relative markdown links, images, and anchors resolve to existing files" do
      link_regex =
        ~r/(?:!?\[[^\]]*\]\(([^)]+)\)|<img[^>]+src=["']([^"']+)["']|<a[^>]+href=["']([^"']+)["'])/

      broken_links =
        Enum.flat_map(@target_docs, fn file ->
          dir = Path.dirname(file)
          content = File.read!(file)

          Regex.scan(link_regex, content)
          |> Enum.flat_map(fn matches ->
            target = Enum.drop(matches, 1) |> Enum.find(&(&1 != "" and &1 != nil))
            target = String.trim(target || "")

            cond do
              target == "" ->
                []

              # External links
              String.starts_with?(target, ["http://", "https://", "mailto:", "ftp:"]) ->
                []

              # In-page anchor only
              String.starts_with?(target, "#") ->
                []

              true ->
                path_part =
                  target
                  |> String.split("#")
                  |> List.first()
                  |> String.split("?")
                  |> List.first()

                resolved = Path.expand(path_part, dir)

                if File.exists?(resolved) do
                  []
                else
                  [
                    {Path.relative_to(file, @repo_root), target,
                     Path.relative_to(resolved, @repo_root)}
                  ]
                end
            end
          end)
        end)

      assert broken_links == [],
             "Found broken internal relative links in documentation: #{inspect(broken_links)}"
    end

    test "all user guides in docs/ are indexed in README.md" do
      readme_path = Path.join(@repo_root, "README.md")
      readme_content = File.read!(readme_path)

      docs_files = Path.wildcard(Path.join([@repo_root, "docs", "*.md"]))

      unindexed =
        Enum.reject(docs_files, fn doc_file ->
          basename = Path.basename(doc_file)
          String.contains?(readme_content, basename)
        end)
        |> Enum.map(&Path.relative_to(&1, @repo_root))

      assert unindexed == [],
             "The following docs are not referenced in README.md: #{inspect(unindexed)}"
    end

    test "all referenced repository file paths in docs exist on disk" do
      code_path_regex = ~r/`((?:lib|test|config|priv|scripts)\/[a-zA-Z0-9_\/.-]+)`/

      missing_paths =
        Enum.flat_map(@target_docs, fn file ->
          content = File.read!(file)

          Regex.scan(code_path_regex, content)
          |> Enum.flat_map(fn [_, path] ->
            clean_path =
              path
              |> String.trim_trailing(".")
              |> String.trim_trailing(":")
              |> String.trim_trailing(",")

            resolved = Path.expand(clean_path, @repo_root)

            if File.exists?(resolved) do
              []
            else
              [{Path.relative_to(file, @repo_root), clean_path}]
            end
          end)
        end)

      assert missing_paths == [],
             "Found nonexistent repository paths referenced in docs: #{inspect(missing_paths)}"
    end

    test "no unresolved placeholder or TODO tokens exist in documentation" do
      placeholder_regex = ~r/\b(TODO|TBD|FIXME|\[placeholder\])\b/

      findings =
        Enum.flat_map(@target_docs, fn file ->
          content = File.read!(file)

          case Regex.scan(placeholder_regex, content) do
            [] -> []
            matches -> [{Path.relative_to(file, @repo_root), matches}]
          end
        end)

      assert findings == [],
             "Found unresolved placeholder tokens in documentation: #{inspect(findings)}"
    end

    test "documented mix commands in README.md and docs/*.md match valid mix tasks or aliases" do
      # Extract `mix <subcommand>` invocations from code blocks
      mix_cmd_regex = ~r/mix\s+([a-zA-Z0-9._-]+)/

      documented_subcommands =
        Enum.flat_map(@target_docs, fn file ->
          file
          |> Path.expand(@repo_root)
          |> File.read!()
          |> then(&Regex.scan(mix_cmd_regex, &1))
          |> Enum.map(fn [_, subcmd] -> {Path.relative_to(file, @repo_root), subcmd} end)
        end)
        |> Enum.uniq()

      # Common core mix tasks and framework tasks
      core_tasks =
        ~w(setup test format compile phx.server assets.setup assets.build assets.deploy ecto.reset ecto.setup ecto.create ecto.migrate phx.gen.secret deps.get deps.compile run credo dialyzer help clean)

      # Custom Cympho mix tasks
      cympho_tasks =
        Path.wildcard(Path.join([@repo_root, "lib", "mix", "tasks", "*.ex"]))
        |> Enum.map(fn path ->
          Path.basename(path, ".ex")
        end)

      valid_tasks = MapSet.new(core_tasks ++ cympho_tasks)

      invalid_commands =
        Enum.reject(documented_subcommands, fn {_file, cmd} ->
          MapSet.member?(valid_tasks, cmd)
        end)

      assert invalid_commands == [],
             "Found undocumented/invalid mix tasks in docs: #{inspect(invalid_commands)}"
    end
  end
end
