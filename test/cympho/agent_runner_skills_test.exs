defmodule Cympho.AgentRunnerSkillsTest do
  use ExUnit.Case, async: true

  alias Cympho.AgentRunner

  describe "build_prompt/3" do
    test "builds prompt without skills" do
      issue = %{id: "TEST-123", title: "Test Issue", description: "Test description"}

      prompt = AgentRunner.build_prompt(issue, [])

      assert prompt =~ "Issue ID: TEST-123"
      assert prompt =~ "Title: Test Issue"
      assert prompt =~ "Test description"
      refute prompt =~ "Available Skills"
    end

    test "builds prompt with skills" do
      issue = %{id: "TEST-456", title: "Test Issue", description: "Test description"}

      skills = [
        %{
          identifier: "test_skill",
          name: "Test Skill",
          version: "1.0.0",
          capabilities: ["file_io", "web_search"],
          description: "A test skill",
          entrypoint: "test.sh"
        }
      ]

      prompt = AgentRunner.build_prompt(issue, skills: skills)

      assert prompt =~ "Issue ID: TEST-456"
      assert prompt =~ "Title: Test Issue"
      assert prompt =~ "Available Skills"
      assert prompt =~ "### Skill: Test Skill (1.0.0)"
      assert prompt =~ "Identifier: `test_skill`"
      assert prompt =~ "Capabilities: file_io, web_search"
    end

    test "builds prompt with multiple skills" do
      issue = %{id: "TEST-789", title: "Test Issue", description: "Test description"}

      skills = [
        %{
          identifier: "skill_one",
          name: "Skill One",
          version: "1.0.0",
          capabilities: ["file_io"],
          description: "First skill",
          entrypoint: "one.sh"
        },
        %{
          identifier: "skill_two",
          name: "Skill Two",
          version: "2.0.0",
          capabilities: ["web_search", "api_call"],
          description: "Second skill",
          entrypoint: "two.sh"
        }
      ]

      prompt = AgentRunner.build_prompt(issue, skills: skills)

      assert prompt =~ "Available Skills"
      assert prompt =~ "### Skill: Skill One (1.0.0)"
      assert prompt =~ "Identifier: `skill_one`"
      assert prompt =~ "Capabilities: file_io"
      assert prompt =~ "### Skill: Skill Two (2.0.0)"
      assert prompt =~ "Identifier: `skill_two`"
      assert prompt =~ "Capabilities: web_search, api_call"
    end

    test "handles skills with missing capabilities" do
      issue = %{id: "TEST-999", title: "Test Issue", description: "Test description"}

      skills = [
        %{
          identifier: "no_caps_skill",
          name: "No Caps Skill",
          version: "1.0.0",
          capabilities: [],
          description: "A skill with no capabilities",
          entrypoint: "no_caps.sh"
        }
      ]

      prompt = AgentRunner.build_prompt(issue, skills: skills)

      assert prompt =~ "Available Skills"
      assert prompt =~ "### Skill: No Caps Skill (1.0.0)"
      assert prompt =~ "Identifier: `no_caps_skill`"
      assert prompt =~ "Capabilities: none"
    end

    test "handles skills with nil capabilities" do
      issue = %{id: "TEST-NIL", title: "Test Issue", description: "Test description"}

      skills = [
        %{
          identifier: "nil_caps_skill",
          name: "Nil Caps Skill",
          version: "1.0.0",
          capabilities: nil,
          description: "A skill with nil capabilities",
          entrypoint: "nil_caps.sh"
        }
      ]

      prompt = AgentRunner.build_prompt(issue, skills: skills)

      assert prompt =~ "Available Skills"
      assert prompt =~ "### Skill: Nil Caps Skill (1.0.0)"
      assert prompt =~ "Identifier: `nil_caps_skill`"
      assert prompt =~ "Capabilities: none"
    end
  end
end
