defmodule Cympho.Docs.Content do
  @moduledoc """
  Canonical documentation repository for Cympho.
  Stores structured documentation entries across 8 core tracks with rich,
  human-friendly content, code snippets, and precomputed navigational links.
  """

  alias Cympho.Docs.{DocEntry, Section, Topic}

  @doc """
  Returns all top-level documentation topics with nested sections.
  """
  def topics do
    raw_topics()
  end

  @doc """
  Finds a topic by slug.
  """
  def get_topic(topic_slug) when is_binary(topic_slug) do
    Enum.find(topics(), &(&1.slug == topic_slug))
  end

  def get_topic(_), do: nil

  @doc """
  Returns all documentation entries in sequential reading order.
  """
  def all_docs do
    build_all_docs()
  end

  @doc """
  Finds a document entry by topic slug and section slug.
  """
  def get_doc(topic_slug, section_slug) when is_binary(topic_slug) and is_binary(section_slug) do
    Enum.find(all_docs(), fn doc ->
      doc.topic_slug == topic_slug and doc.section_slug == section_slug
    end)
  end

  def get_doc(_, _), do: nil

  @doc """
  Returns the very first documentation entry (Getting Started Overview).
  """
  def first_doc do
    List.first(all_docs())
  end

  @doc """
  Returns the default (first) document for a given topic.
  """
  def default_doc_for_topic(topic_slug) when is_binary(topic_slug) do
    case Enum.find(all_docs(), &(&1.topic_slug == topic_slug)) do
      nil -> first_doc()
      doc -> doc
    end
  end

  def default_doc_for_topic(_), do: first_doc()

  # ---------------------------------------------------------------------------
  # Topic Definitions
  # ---------------------------------------------------------------------------

  defp raw_topics do
    [
      %Topic{
        id: "getting-started",
        slug: "getting-started",
        title: "Getting Started",
        summary: "Introduction to Cympho, local development setup, and creating your company.",
        icon: "hero-rocket-launch-mini",
        order: 1,
        sections: [
          %Section{
            id: "overview",
            slug: "overview",
            title: "Overview",
            summary: "What is Cympho? The autonomous company OS.",
            topic_slug: "getting-started",
            order: 1
          },
          %Section{
            id: "quickstart",
            slug: "quickstart",
            title: "Quickstart",
            summary: "Get Cympho running locally in under five minutes.",
            topic_slug: "getting-started",
            order: 2
          },
          %Section{
            id: "onboarding",
            slug: "onboarding",
            title: "First-Run Onboarding",
            summary: "Setting up your organization and first agent workforce.",
            topic_slug: "getting-started",
            order: 3
          },
          %Section{
            id: "interface-modes",
            slug: "interface-modes",
            title: "Interface Modes",
            summary: "Navigating between Simple and Advanced operational modes.",
            topic_slug: "getting-started",
            order: 4
          }
        ]
      },
      %Topic{
        id: "core-concepts",
        slug: "core-concepts",
        title: "Core Concepts",
        summary:
          "Understand actors, company hierarchy, state machines, and runtime power levels.",
        icon: "hero-cube-transparent-mini",
        order: 2,
        sections: [
          %Section{
            id: "actors",
            slug: "actors",
            title: "Actors & Roles",
            summary: "Human owners, board members, and AI agent roles.",
            topic_slug: "core-concepts",
            order: 1
          },
          %Section{
            id: "company-hierarchy",
            slug: "company-hierarchy",
            title: "Company Hierarchy",
            summary: "Multi-tenancy scoping, roles, and resource isolation.",
            topic_slug: "core-concepts",
            order: 2
          },
          %Section{
            id: "issue-lifecycle",
            slug: "issue-lifecycle",
            title: "Issue Lifecycle",
            summary: "State machine progression, lock versions, and assignments.",
            topic_slug: "core-concepts",
            order: 3
          },
          %Section{
            id: "runtime-modes",
            slug: "runtime-modes",
            title: "Runtime Modes",
            summary: "Managing power budgets from Full Power to Review Mode.",
            topic_slug: "core-concepts",
            order: 4
          }
        ]
      },
      %Topic{
        id: "workflows",
        slug: "workflows",
        title: "Everyday Workflows",
        summary: "Collaborating with agents on tasks, kanban boards, reviews, and company goals.",
        icon: "hero-view-columns-mini",
        order: 3,
        sections: [
          %Section{
            id: "issues",
            slug: "issues",
            title: "Tasks & Issues",
            summary: "Authoring briefs, setting priority, and task routing.",
            topic_slug: "workflows",
            order: 1
          },
          %Section{
            id: "kanban",
            slug: "kanban",
            title: "Kanban Board",
            summary: "Visual drag-and-drop workflows and flow health indicators.",
            topic_slug: "workflows",
            order: 2
          },
          %Section{
            id: "reviews",
            slug: "reviews",
            title: "Human Review Gates",
            summary: "Inspecting deliverables, delivery notes, and approval loops.",
            topic_slug: "workflows",
            order: 3
          },
          %Section{
            id: "inbox",
            slug: "inbox",
            title: "Unified Inbox",
            summary: "Handling unread agent notices, mentions, and action requests.",
            topic_slug: "workflows",
            order: 4
          },
          %Section{
            id: "projects-goals",
            slug: "projects-goals",
            title: "Projects & Goals",
            summary: "Aligning tactical work with company missions and milestones.",
            topic_slug: "workflows",
            order: 5
          }
        ]
      },
      %Topic{
        id: "ai-agents",
        slug: "ai-agents",
        title: "AI Agents & Adapters",
        summary: "Autonomous roles, adapter harnesses, swarms, prompt tuning, and agent rentals.",
        icon: "hero-cpu-chip-mini",
        order: 4,
        sections: [
          %Section{
            id: "agent-roles",
            slug: "agent-roles",
            title: "Agent Roles",
            summary: "Executive leadership, product managers, designers, and engineers.",
            topic_slug: "ai-agents",
            order: 1
          },
          %Section{
            id: "adapters",
            slug: "adapters",
            title: "Agent Adapters",
            summary: "Connecting Claude Code, Codex, Cursor, HTTP, and Process runtimes.",
            topic_slug: "ai-agents",
            order: 2
          },
          %Section{
            id: "cli-harnesses",
            slug: "cli-harnesses",
            title: "CLI Harnesses",
            summary: "Configuring local command wrappers and environment presets.",
            topic_slug: "ai-agents",
            order: 3
          },
          %Section{
            id: "swarm-mode",
            slug: "swarm-mode",
            title: "Swarm Mode",
            summary: "One-time issue fan-out into worker packets and CTO synthesis.",
            topic_slug: "ai-agents",
            order: 4
          },
          %Section{
            id: "instruction-studio",
            slug: "instruction-studio",
            title: "Instruction Studio",
            summary: "Inspecting prompts, editing instructions, and testing outputs.",
            topic_slug: "ai-agents",
            order: 5
          },
          %Section{
            id: "agrenting",
            slug: "agrenting",
            title: "Agrenting Marketplace",
            summary: "Connecting and renting external marketplace agents.",
            topic_slug: "ai-agents",
            order: 6
          }
        ]
      },
      %Topic{
        id: "routines",
        slug: "routines",
        title: "Routines & Triggers",
        summary: "Automating recurring company operations with cron expressions and webhooks.",
        icon: "hero-arrow-path-mini",
        order: 5,
        sections: [
          %Section{
            id: "scheduled-routines",
            slug: "scheduled-routines",
            title: "Scheduled Routines",
            summary: "Recurring background maintenance using Quantum cron schedules.",
            topic_slug: "routines",
            order: 1
          },
          %Section{
            id: "webhook-triggers",
            slug: "webhook-triggers",
            title: "Webhook Triggers",
            summary: "Replay-safe public webhook endpoints with HMAC verification.",
            topic_slug: "routines",
            order: 2
          },
          %Section{
            id: "run-history",
            slug: "run-history",
            title: "Run History & Audits",
            summary: "Inspecting execution logs, retries, and routine parameters.",
            topic_slug: "routines",
            order: 3
          }
        ]
      },
      %Topic{
        id: "workspaces",
        slug: "workspaces",
        title: "Workspaces & Previews",
        summary: "Isolated git worktrees, background runtime services, and live previews.",
        icon: "hero-rectangle-stack-mini",
        order: 6,
        sections: [
          %Section{
            id: "git-worktrees",
            slug: "git-worktrees",
            title: "Git Worktrees",
            summary: "Dedicated file trees per task to eliminate workspace collisions.",
            topic_slug: "workspaces",
            order: 1
          },
          %Section{
            id: "runtime-services",
            slug: "runtime-services",
            title: "Runtime Services",
            summary: "Dev servers, leased ports, and service health probes.",
            topic_slug: "workspaces",
            order: 2
          },
          %Section{
            id: "live-previews",
            slug: "live-previews",
            title: "Live Previews",
            summary: "Secure browser previews with isolated capability tokens.",
            topic_slug: "workspaces",
            order: 3
          }
        ]
      },
      %Topic{
        id: "governance",
        slug: "governance",
        title: "Governance & Budgets",
        summary: "Board approvals, spend limits, decision reversals, and cryptographic audits.",
        icon: "hero-shield-check-mini",
        order: 7,
        sections: [
          %Section{
            id: "board-approvals",
            slug: "board-approvals",
            title: "Board Approvals",
            summary: "Voting quorums and authorization gates for high-risk actions.",
            topic_slug: "governance",
            order: 1
          },
          %Section{
            id: "execution-policies",
            slug: "execution-policies",
            title: "Execution Policies",
            summary: "Tool restrictions, budget ceilings, and inheritance trees.",
            topic_slug: "governance",
            order: 2
          },
          %Section{
            id: "spend-tracking",
            slug: "spend-tracking",
            title: "Spend & Budgets",
            summary: "Monitoring agent token costs, provider posture, and alerts.",
            topic_slug: "governance",
            order: 3
          },
          %Section{
            id: "decision-reversals",
            slug: "decision-reversals",
            title: "Decision Reversals",
            summary: "Audited decision logs with atomic rollback mechanisms.",
            topic_slug: "governance",
            order: 4
          },
          %Section{
            id: "audit-trails",
            slug: "audit-trails",
            title: "Audit Trails",
            summary: "Cryptographic hash chains and principal permissions.",
            topic_slug: "governance",
            order: 5
          }
        ]
      },
      %Topic{
        id: "mcp-api",
        slug: "mcp-api",
        title: "MCP & API Reference",
        summary: "Model Context Protocol, REST API endpoints, webhooks, and BEAM telemetry.",
        icon: "hero-code-bracket-square-mini",
        order: 8,
        sections: [
          %Section{
            id: "mcp-overview",
            slug: "mcp-overview",
            title: "MCP Overview",
            summary: "Model Context Protocol architecture and agent authentication.",
            topic_slug: "mcp-api",
            order: 1
          },
          %Section{
            id: "mcp-tools",
            slug: "mcp-tools",
            title: "MCP Built-in Tools",
            summary: "Comprehensive contracts for all 9 built-in MCP tools.",
            topic_slug: "mcp-api",
            order: 2
          },
          %Section{
            id: "dynamic-tools",
            slug: "dynamic-tools",
            title: "Dynamic Plugin Tools",
            summary: "Dynamic tool discovery, grants, and runtime timeouts.",
            topic_slug: "mcp-api",
            order: 3
          },
          %Section{
            id: "rest-api",
            slug: "rest-api",
            title: "REST API",
            summary: "JSON endpoints for issues, projects, goals, routines, and workspaces.",
            topic_slug: "mcp-api",
            order: 4
          },
          %Section{
            id: "webhooks",
            slug: "webhooks",
            title: "Inbound Webhooks",
            summary: "Connecting GitHub webhooks and Telegram notifications.",
            topic_slug: "mcp-api",
            order: 5
          },
          %Section{
            id: "telemetry-beam",
            slug: "telemetry-beam",
            title: "BEAM & Tool Traces",
            summary: "Tool call traces and LiveDashboard BEAM introspection.",
            topic_slug: "mcp-api",
            order: 6
          }
        ]
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Document Assembly & Navigation Linking
  # ---------------------------------------------------------------------------

  defp build_all_docs do
    entries = raw_doc_entries()
    total = length(entries)

    entries
    |> Enum.with_index()
    |> Enum.map(fn {%DocEntry{} = entry, index} ->
      prev_doc =
        if index > 0 do
          prev = Enum.at(entries, index - 1)
          %{title: prev.title, path: "/docs/#{prev.topic_slug}/#{prev.section_slug}"}
        else
          nil
        end

      next_doc =
        if index < total - 1 do
          nxt = Enum.at(entries, index + 1)
          %{title: nxt.title, path: "/docs/#{nxt.topic_slug}/#{nxt.section_slug}"}
        else
          nil
        end

      anchors = extract_anchors(entry.markdown_content)
      html_content = render_html_with_anchors(entry.markdown_content)

      %{
        entry
        | prev_doc: prev_doc,
          next_doc: next_doc,
          anchors: anchors,
          html_content: html_content
      }
    end)
  end

  defp extract_anchors(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      cond do
        String.starts_with?(line, "### ") ->
          title = String.trim_leading(line, "### ") |> String.trim()
          id = slugify(title)
          [%{id: id, title: title, level: 3} | acc]

        String.starts_with?(line, "## ") ->
          title = String.trim_leading(line, "## ") |> String.trim()
          id = slugify(title)
          [%{id: id, title: title, level: 2} | acc]

        true ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s-]/u, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end

  defp render_html_with_anchors(markdown) do
    safe_html = CymphoWeb.Markdown.to_html(markdown)
    html_string = Phoenix.HTML.safe_to_string(safe_html)

    # Inject id="..." into <h2> and <h3> tags
    transformed =
      Regex.replace(~r/<(h[23])>([^<]+)<\/\1>/, html_string, fn _full, tag, content ->
        id = slugify(content)
        "<#{tag} id=\"#{id}\">#{content}</#{tag}>"
      end)

    Phoenix.HTML.raw(transformed)
  end

  # ---------------------------------------------------------------------------
  # Document Definitions (All 8 Tracks, 36 Documents)
  # ---------------------------------------------------------------------------

  defp raw_doc_entries do
    getting_started_docs() ++
      core_concepts_docs() ++
      workflows_docs() ++
      ai_agents_docs() ++
      routines_docs() ++
      workspaces_docs() ++
      governance_docs() ++
      mcp_api_docs()
  end

  # --- Track 1: Getting Started ---

  defp getting_started_docs do
    [
      %DocEntry{
        id: "getting-started-overview",
        topic_slug: "getting-started",
        section_slug: "overview",
        title: "What is Cympho?",
        summary:
          "Cympho is an autonomous company OS that coordinates AI agents, human operators, and execution sandboxes.",
        keywords: ["overview", "philosophy", "autonomous company", "agent team", "orchestration"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## The Autonomous Company OS

        Cympho is an operating system for AI agents working alongside humans. Unlike simple code generation assistants or chatbots that run in isolation, Cympho organizes agents into a structured company hierarchy with defined roles, persistent memories, execution policies, and governance guardrails.

        In Cympho, agents do not simply answer one-off questions:
        - They are assigned **issues** with clear business briefs.
        - They operate inside **isolated git worktrees** to prevent workspace collisions.
        - They coordinate through **Model Context Protocol (MCP)** tools and Phoenix Channels.
        - They report work products through **human review gates** before code enters production.

        ## Why Cympho?

        ### Organizational Clarity
        Agents need structure just like human teams. When an issue arrives:
        1. **The CEO Agent** assesses high-level strategy and routes work to the right department.
        2. **The CTO Agent** breaks complex problems into technical specifications and worker packets.
        3. **The Product Manager** defines acceptance criteria and edge cases.
        4. **Specialized Engineers** write code, run test suites, and produce verifiable work products.

        ### Multi-Tenant Isolation
        Every company in Cympho is strictly isolated by `company_id`. An agent belonging to Company A can never view issues, projects, or API keys belonging to Company B.

        ### Verifiable Deliverables
        Agents never silently push changes to production. Every pull request or patch is linked to an issue, accompanied by a delivery note, and gated by human review or board approval.
        """
      },
      %DocEntry{
        id: "getting-started-quickstart",
        topic_slug: "getting-started",
        section_slug: "quickstart",
        title: "Quickstart Guide",
        summary:
          "Set up and boot Cympho on your local development machine in under five minutes.",
        keywords: ["quickstart", "installation", "setup", "mix", "postgres", "elixir"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Prerequisites

        Before starting, ensure your local development machine has the following dependencies installed:
        - **Elixir**: `1.19.5` (compiled with OTP 28)
        - **Erlang/OTP**: `28.4.3`
        - **PostgreSQL**: `14+` running on `localhost:5432`
        - **Node.js**: `20+` (optional, for asset bundling)

        ## Installation Steps

        ### 1. Clone the Repository
        Clone the codebase and navigate into the project directory:

        ```bash
        git clone https://github.com/cympho/cympho.git
        cd cympho
        ```

        ### 2. Install Dependencies & Prepare Database
        Run the setup alias to fetch dependencies, create the database, run migrations, and seed initial records:

        ```bash
        mix setup
        ```

        To reset your local database at any time:
        ```bash
        mix ecto.reset
        ```

        ### 3. Start the Phoenix Server
        Start Cympho with an interactive IEx console or as a standard server:

        ```bash
        # Standard server on http://localhost:4329
        mix phx.server

        # Or with interactive Elixir shell
        iex -S mix phx.server
        ```

        Open [http://localhost:4329](http://localhost:4329) in your browser.

        ## Running Tests
        Run the automated test suite with:

        ```bash
        mix test
        ```

        The test runner automatically creates and migrates `cympho_test` using credentials `paperclip/paperclip@localhost/cympho_test`.
        """
      },
      %DocEntry{
        id: "getting-started-onboarding",
        topic_slug: "getting-started",
        section_slug: "onboarding",
        title: "First-Run Onboarding",
        summary:
          "Initialize your first company, configure provider API keys, and launch initial agents.",
        keywords: ["onboarding", "company setup", "api keys", "anthropic", "openai"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Guided Organization Setup

        When you first open Cympho, you are guided through the onboarding wizard at `/onboarding`.

        ### 1. Create Your Company
        Provide a company name and workspace slug. The slug forms your unique workspace identifier and scopes all projects, issues, and agents.

        ### 2. Configure Model Provider Keys
        Cympho supports leading AI model providers. In development, you can use local Claude wrappers (`cz` or `cm`) or provide API keys:
        - **Anthropic**: Used for Claude 3.5 Sonnet and Opus models.
        - **OpenAI**: Used for GPT-4o, o1, and Codex runtimes.
        - **Custom Endpoints**: Connect self-hosted OpenAI-compatible LLM servers.

        Provider keys are stored securely using AES-GCM encryption with fail-closed production guarantees.

        ### 3. Seed Starter Workforce
        The onboarding flow can automatically generate a balanced starter team:
        - **Chief Executive Officer (CEO)**: Oversees company strategy and goals.
        - **Chief Technology Officer (CTO)**: Architects solutions and coordinates swarms.
        - **Lead Engineer**: Implements features and resolves bugs.
        - **Product Manager**: Defines specifications and verifies deliverables.
        """
      },
      %DocEntry{
        id: "getting-started-interface-modes",
        topic_slug: "getting-started",
        section_slug: "interface-modes",
        title: "Simple vs Advanced UI Modes",
        summary:
          "Switch between guided clarity for non-technical users and full telemetry for operators.",
        keywords: [
          "simple mode",
          "advanced mode",
          "ui toggle",
          "keyboard shortcut",
          "focus queue"
        ],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Adaptive Interface Density

        Cympho accommodates both non-technical business operators and systems engineers through two specialized interface modes: **Simple Mode** and **Advanced Mode**.

        You can toggle between modes at any time by pressing <kbd>U</kbd> or using the mode switch in the header.

        ## Simple Mode (Default)
        Simple Mode prioritizes distraction-free focus:
        - **Focus Queue**: Highlights tasks currently demanding human attention (pending reviews, required inputs, blockers).
        - **Simplified Navigation**: Hides low-level telemetry, worktree paths, process IDs, and raw JSON payloads.
        - **Plain English Summaries**: Translates technical errors and agent states into human-friendly language.

        ## Advanced Mode
        Advanced Mode unlocks the complete operational cockpit:
        - **BEAM Telemetry**: Live process mailboxes, ETS tables, and supervisor trees at `/beam`.
        - **Instruction Studio**: Inspect and tweak system prompts and agent instruction contracts.
        - **Worktree Sandboxes**: Direct access to git branch paths, leased ports, and runtime services.
        - **Tool-Call Traces**: Cryptographic audit records of every MCP tool invocation.
        """
      }
    ]
  end

  # --- Track 2: Core Concepts ---

  defp core_concepts_docs do
    [
      %DocEntry{
        id: "core-concepts-actors",
        topic_slug: "core-concepts",
        section_slug: "actors",
        title: "Actors & Roles",
        summary:
          "Understand the roles of human operators, board members, and specialized AI agents.",
        keywords: ["actors", "roles", "ceo", "cto", "engineer", "board member", "permissions"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## System Actors

        Every action in Cympho is attributed to an authenticated actor. The platform distinguishes between human users and autonomous AI agents:

        ### 1. Human Operators
        - **Company Owner**: Full administrative control over company settings, billing, API keys, and member invites.
        - **Admin**: Manages projects, routines, execution policies, and agent configurations.
        - **Member**: Collaborates on issues, submits comments, and requests agent runs.
        - **Board Member**: Holds voting seats for high-risk governance approvals (spend ceiling increases, company exports).

        ### 2. Autonomous AI Agents
        AI agents are autonomous entities assigned specific company roles:
        - **CEO (`ceo`)**: Reviews incoming business goals, coordinates cross-functional initiatives, and delegates tasks to directors.
        - **CTO (`cto`)**: Breaks complex architecture into discrete engineering tickets, orchestrates swarm packets, and synthesizes results.
        - **Product Manager (`product_manager`)**: Drafts user stories, acceptance criteria, and priority rankings.
        - **Designer (`designer`)**: Produces UI specifications, component tokens, and user experience reviews.
        - **Engineer (`engineer`)**: Implements code changes, runs tests, fixes bugs, and attaches patches.
        - **QA Engineer (`qa_engineer`)**: Designs test matrices, executes edge-case verifications, and validates fixes.
        """
      },
      %DocEntry{
        id: "core-concepts-company-hierarchy",
        topic_slug: "core-concepts",
        section_slug: "company-hierarchy",
        title: "Company Hierarchy & Multi-Tenancy",
        summary: "Multi-tenant company scoping, RBAC permissions, and total data isolation.",
        keywords: ["multi-tenancy", "rbac", "company_id", "security", "isolation"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Strict Multi-Tenant Scoping

        Cympho is architected from the ground up for multi-tenant isolation:
        - All database records (`issues`, `agents`, `projects`, `routines`, `approvals`) carry a mandatory `company_id` foreign key.
        - All Phoenix LiveView sockets and HTTP pipelines resolve the active company before processing user requests.
        - Phoenix PubSub broadcast topics are scoped per company (e.g. `company:{company_id}:activity`, `company:{company_id}:decisions`).

        ## Cross-Tenant Protection
        The system guards against cross-tenant data leakage at multiple levels:
        1. **Database Queries**: Context queries explicitly include `where: [company_id: ^company_id]`.
        2. **MCP Tool Scoping**: The Model Context Protocol server extracts the calling agent's `company_id` directly from its authentication token; agents cannot query or modify resources outside their own company.
        3. **Worktree Sandboxing**: Git workspaces and preview ports are partitioned on disk by company UUID.
        """
      },
      %DocEntry{
        id: "core-concepts-issue-lifecycle",
        topic_slug: "core-concepts",
        section_slug: "issue-lifecycle",
        title: "Issue Lifecycle & State Machine",
        summary:
          "State machine transitions, optimistic concurrency control, and assignment flows.",
        keywords: ["issue lifecycle", "state machine", "lock_version", "kanban", "in_progress"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## Issue State Progression

        Issues move through a formal state machine managed by `Cympho.Issues.StateMachine`:

        ```
        [Backlog] ──> [Todo] ──> [In Progress] ──> [In Review] ──> [Done]
             │          │              │                 │
             └──> [Blocked] <──────────┴─────────────────┘
        ```

        ### State Definitions
        - **`backlog`**: Ideas and unscheduled requirements awaiting prioritization.
        - **`todo`**: Prioritized tasks ready for assignment to an agent or human.
        - **`in_progress`**: Currently being executed by an active agent session or developer.
        - **`in_review`**: Execution completed; deliverable attached and awaiting human sign-off.
        - **`done`**: Successfully verified and closed.
        - **`blocked`**: Work halted due to missing information, dependency failures, or policy rejections.

        ## Concurrency Protection via `lock_version`
        To prevent concurrent update collisions when multiple agents or automated routines touch the same issue simultaneously, Cympho utilizes Ecto optimistic locking. Every issue update increments `lock_version`. If a stale session attempts to transition an issue, the mutation fails gracefully and triggers a re-read.
        """
      },
      %DocEntry{
        id: "core-concepts-runtime-modes",
        topic_slug: "core-concepts",
        section_slug: "runtime-modes",
        title: "Runtime Power Modes",
        summary:
          "Manage autonomous execution posture from Full Power to complete emergency stop.",
        keywords: [
          "runtime modes",
          "full power",
          "low power",
          "paused",
          "review mode",
          "kill switch"
        ],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Execution Power Posture

        Operators maintain complete authority over how aggressively agents execute through company-wide runtime controls:

        ### 1. Full Power
        The default operational posture. Agents autonomously pick up `todo` issues, execute tool calls, and schedule recurring routines according to their configured heartbeats.

        ### 2. Low Power
        Conserves API spend and compute resources. Background routine triggers and low-priority backlog tasks are paused. Only `critical` and `high` priority issues are processed.

        ### 3. Paused
        Freezes active agent sessions cleanly. Running tasks complete their current tool call, and queued wakes are safely preserved in the database without loss of state.

        ### 4. Stopped (Emergency Kill Switch)
        Immediately terminates all active agent processes, revokes active preview port leases, and halts the dispatcher.

        ### 5. Review Mode
        Agents generate plans, proposals, and diffs, but execution stops before any disk writes or external tool calls occur, allowing offline review without token expenditure.
        """
      }
    ]
  end

  # --- Track 3: Everyday Workflows ---

  defp workflows_docs do
    [
      %DocEntry{
        id: "workflows-issues",
        topic_slug: "workflows",
        section_slug: "issues",
        title: "Tasks & Issues",
        summary:
          "Create clear briefs, assign tasks to specialized roles, and track delivery progress.",
        keywords: ["issues", "tasks", "authoring", "priority", "brief", "quick create"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## Authoring Effective Issue Briefs

        Issues in Cympho represent discrete units of work. Because AI agents rely on clear instructions, writing well-structured briefs leads to superior execution.

        ### Creating an Issue
        Press <kbd>C</kbd> anywhere in the application to open the **Quick Issue Creator**, or navigate to `/issues/new`.

        ### Recommended Brief Structure
        A high-performing issue brief includes:
        1. **Objective**: One sentence explaining the desired outcome.
        2. **Context**: Relevant background, affected systems, or link to a parent goal.
        3. **Acceptance Criteria**: Verifiable conditions that must pass before the issue can be marked done.
        4. **Constraints**: Libraries to avoid, backward-compatibility requirements, or budget limits.

        ### Role-Based Routing
        You can assign an issue to a specific agent (e.g. "Senior Backend Engineer") or route it to an abstract role (e.g. `engineer`). When routed to a role, Cympho's auto-assignment engine assigns the task to the first available idle agent with that role.
        """
      },
      %DocEntry{
        id: "workflows-kanban",
        topic_slug: "workflows",
        section_slug: "kanban",
        title: "Kanban Board & Flow Health",
        summary: "Visual drag-and-drop workflow management with live status transitions.",
        keywords: ["kanban", "board", "drag and drop", "sortable", "flow health"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Visual Task Management

        The Kanban Board at `/kanban` provides a bird's-eye view of your company's real-time productivity:
        - Drag cards across columns to update issue statuses in real time.
        - Changes synchronize instantly across all connected human and agent sessions over Phoenix Channels.
        - Cards display assigned agent avatars, priority badges, and active work indicators.

        ## Flow Health Indicators
        The board header highlights flow bottlenecks:
        - **WIP Limits**: Warns when too many tasks are in progress simultaneously.
        - **Review Backlog**: Alerts when completed agent tasks are waiting for human review.
        - **Blocked Counter**: Displays tasks blocked by policy gates or missing dependencies.
        """
      },
      %DocEntry{
        id: "workflows-reviews",
        topic_slug: "workflows",
        section_slug: "reviews",
        title: "Human Review Gates",
        summary: "Inspect work products, delivery notes, and approve or request changes safely.",
        keywords: ["reviews", "delivery note", "work products", "approval", "human in the loop"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## Human-in-the-Loop Safeguards

        When an agent finishes working on an issue, it moves the issue to `in_review` and attaches a **Work Product** (code patch, specification, or report) and a **Delivery Note**.

        ## The Review Queue
        The Review Queue at `/reviews` aggregates all deliverables awaiting operator approval:
        - **Delivery Note**: The agent's executive summary of what was changed and why.
        - **Work Product Diff**: Unified diff viewer showing exact code changes.
        - **Verification Evidence**: Test suite results and build artifacts produced during execution.

        ## Review Actions
        1. **Approve**: Merges the work product, marks the issue `done`, and notifies the agent.
        2. **Request Changes**: Reopens the issue (`todo` or `in_progress`) with mandatory human feedback. The feedback is injected directly into the agent's prompt memory for its next run.
        3. **Block / Reject**: Marks the issue as blocked with an explanatory audit note.
        """
      },
      %DocEntry{
        id: "workflows-inbox",
        topic_slug: "workflows",
        section_slug: "inbox",
        title: "Unified Inbox & Attention",
        summary: "Stay informed of agent handoffs, blocker notices, and unread notifications.",
        keywords: ["inbox", "notifications", "unread badges", "attention", "mentions"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Centralized Notification Hub

        The Unified Inbox at `/inbox` keeps human operators informed of high-signal events without noise:
        - **Questions for Human**: Agents pausing for required clarification or credentials.
        - **Pending Approvals**: Board votes or budget threshold overrides.
        - **Review Requests**: Completed agent deliverables ready for inspection.
        - **System Alerts**: Failed routine runs or provider rate limits.

        ## Real-Time Channel Badging
        Unread counts update instantaneously in the sidebar nav rail using Phoenix PubSub broadcasts (`inbox:{agent_id}` and `company:{company_id}:inbox`). Items can be marked read individually or archived in bulk.
        """
      },
      %DocEntry{
        id: "workflows-projects-goals",
        topic_slug: "workflows",
        section_slug: "projects-goals",
        title: "Projects & Strategic Goals",
        summary: "Organize tasks into projects and link operational work to company milestones.",
        keywords: ["projects", "goals", "milestones", "prefix", "strategy"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Strategic Alignment

        Cympho connects day-to-day tickets to overarching company missions:

        ### Projects
        Projects represent distinct codebases, product modules, or operational units:
        - Each project has an identifier prefix (e.g. `CORE`, `WEB`, `MOBILE`).
        - Issues receive sequential ticket keys (e.g. `CORE-101`, `WEB-42`).
        - Projects can be linked to dedicated git worktree repositories.

        ### Goals
        Goals represent strategic objectives with target completion dates:
        - Progress bars automatically reflect the percentage of linked issues marked `done`.
        - Agents reference active goal priorities when deciding which backlog tickets to prioritize.
        """
      }
    ]
  end

  # --- Track 4: AI Agents & Adapters ---

  defp ai_agents_docs do
    [
      %DocEntry{
        id: "ai-agents-agent-roles",
        topic_slug: "ai-agents",
        section_slug: "agent-roles",
        title: "Agent Roles & Contracts",
        summary: "Specialized roles, contract boundaries, and system prompt playbooks.",
        keywords: ["agent roles", "contracts", "playbooks", "prompts", "responsibilities"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## Role-Based Specialization

        Rather than deploying generic monolithic AI assistants, Cympho assigns each agent a distinct organizational role with tailored system prompts, allowed tool sets, and operational boundaries:

        ### Executive Roles
        - **Chief Executive Officer (`ceo`)**: Focuses on company-level missions, cross-team alignment, and resource allocations. Uses high-level MCP tools to inspect progress and delegate.
        - **Chief Technology Officer (`cto`)**: Responsible for technical architecture, code quality, dependency management, and orchestrating multi-agent swarms.

        ### Functional Roles
        - **Product Manager (`product_manager`)**: Validates specifications, defines test acceptance criteria, and manages feature priorities.
        - **Designer (`designer`)**: Crafts UI layouts, tailwind tokens, and usability feedback.
        - **Engineer (`engineer`)**: Reads codebases, implements features, writes automated tests, and creates work products.
        - **QA Engineer (`qa_engineer`)**: Conducts exploratory tests, regression suites, and boundary value analyses.
        """
      },
      %DocEntry{
        id: "ai-agents-adapters",
        topic_slug: "ai-agents",
        section_slug: "adapters",
        title: "Agent Adapters",
        summary:
          "Behaviour-based runtime adapters for Claude Code, Codex, Cursor, HTTP, and Process.",
        keywords: [
          "adapters",
          "claude_code",
          "codex",
          "cursor",
          "http",
          "process",
          "health check"
        ],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## Pluggable Adapter Architecture

        Cympho abstracts agent execution behind the `Cympho.AgentAdapters.Adapter` Elixir behaviour:

        ```elixir
        defmodule Cympho.AgentAdapters.Adapter do
          @callback run(agent :: Agent.t(), run :: HeartbeatRun.t(), opts :: keyword()) ::
                      {:ok, result :: map()} | {:error, reason :: any()}
          @callback health_check(agent :: Agent.t()) :: :ok | {:error, reason :: any()}
        end
        ```

        ### Supported Adapters
        1. **`claude_code`**: Interacts with the Claude Code CLI harness.
        2. **`codex`**: Executes tasks using OpenAI Codex models and execution sandboxes.
        3. **`cursor`**: Integrates with the Cursor command-line interface.
        4. **`openai_chat`**: Direct API integration with OpenAI chat-completion endpoints.
        5. **`http`**: Dispatches task payloads to external HTTP webhooks or remote agent servers.
        6. **`process`**: Spawns local operating system processes with environment variables and stdin/stdout pipes.

        ### Failover & Health Checks
        `Cympho.AgentAdapters.HealthChecker` monitors adapter availability. An agent's selected adapter is final: if it is unavailable or misconfigured, the run is refused with the reason, and Cympho does not switch to another adapter. Only an explicit runtime-profile fallback chain changes runtime, and only after a provider rate limit, a quota error, or a temporary provider failure.
        """
      },
      %DocEntry{
        id: "ai-agents-cli-harnesses",
        topic_slug: "ai-agents",
        section_slug: "cli-harnesses",
        title: "CLI Harnesses & Claude Wrappers",
        summary: "Configuring local wrappers, environment files, and third-party harnesses.",
        keywords: ["cli", "wrappers", "cz", "cm", "cld", "kimi", "cline", "aider"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## CLI Wrappers & Local Presets

        For local development and cost optimization, Cympho supports custom command wrappers (such as `cz` or `cm`) instead of direct calls to proprietary APIs.

        ### Configuring Claude Wrappers
        Set the environment variable or configure the agent command:

        ```bash
        export CYMPHO_CLAUDE_COMMAND="cz"
        ```

        ### Sourcing `$HOME/.cld`
        In development mode, Cympho automatically sources `$HOME/.cld` before invoking CLI commands. This file is ideal for configuring local credentials:

        ```bash
        # ~/.cld
        export ANTHROPIC_BASE_URL="http://localhost:8080/v1"
        export ANTHROPIC_API_KEY="sk-local-dev-key"
        export ANTHROPIC_MODEL="claude-3-5-sonnet-20241022"
        ```

        *Note: In production environments, credentials must be configured via environment variables or Cympho Secrets rather than personal dotfiles.*

        ### Codex Process Preset
        The `process-codex` preset runs `codex exec --json` and reads Codex's JSONL events for the final message and token usage. codex-cli 0.44.0 and later is known to work; older versions are untested. A wrapper command must pass `--json` through and leave stdout unchanged. If a run prints no JSONL event, it fails with "codex exec --json produced no JSONL events; use codex-cli 0.44.0+ and make wrappers forward --json".
        """
      },
      %DocEntry{
        id: "ai-agents-swarm-mode",
        topic_slug: "ai-agents",
        section_slug: "swarm-mode",
        title: "Swarm Mode Orchestration",
        summary:
          "Fan out complex tasks into parallel worker packets and synthesize through the CTO.",
        keywords: ["swarm mode", "fan out", "worker packets", "synthesis", "cto gate"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## High-Concurrency Swarm Execution

        When an issue requires multi-disciplinary exploration or parallel implementation, **Swarm Mode** fans out the parent issue into temporary, independent worker packets.

        ```
        Parent Issue ──> Fan-Out ──> [Worker 1: Implementation]
                                ──> [Worker 2: Security Audit]
                                ──> [Worker 3: Edge Case Testing]
                                            │
                                            v
                                   [CTO Gate Synthesis]
                                            │
                                            v
                                   [Consolidated PR]
        ```

        ### Specialized Lenses
        Each worker packet can be instructed to adopt a specialized lens:
        - **Security & Integrity**: Audits code for SQL injection, token leaks, and privilege escalations.
        - **Performance**: Analyzes database queries, caching, and BEAM memory overhead.
        - **QA & Edge Cases**: Formulates edge cases, boundary values, and race conditions.

        ### The CTO Gate
        Workers do not report directly to human operators. Instead, the CTO agent reviews all worker deliverables, resolves conflicts, produces a consolidated work product, and submits a unified review request.
        """
      },
      %DocEntry{
        id: "ai-agents-instruction-studio",
        topic_slug: "ai-agents",
        section_slug: "instruction-studio",
        title: "Instruction Studio",
        summary:
          "Inspect rendered system prompts, tune agent behaviors, and test instruction coverage.",
        keywords: ["instruction studio", "system prompt", "prompt engineering", "tuning"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Prompt Engineering & Auditing

        The Instruction Studio at `/instruction-studio` provides complete visibility into what AI agents see before executing tasks:
        - **Live Prompt Preview**: Inspect dynamically generated system prompts including injected company policies, available MCP tools, and recent issue context.
        - **Contract Verification**: Detect ambiguous instructions, missing tool authorizations, or contradictory constraints.
        - **Test Invocations**: Execute dry-run agent prompts to verify behavior before applying changes to production agents.
        """
      },
      %DocEntry{
        id: "ai-agents-agrenting",
        topic_slug: "ai-agents",
        section_slug: "agrenting",
        title: "Agrenting Agent Marketplace",
        summary:
          "Rent specialized external AI agents and integrate them into your company workforce.",
        keywords: ["agrenting", "marketplace", "remote agents", "renting", "skills"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## On-Demand Agent Capacity

        Through the Agrenting integration, companies can rent specialized external agents for temporary workloads (e.g. penetration testing, accessibility auditing, deep performance profiling):
        - **Seamless Attachment**: Rented agents appear alongside internal agents in your team directory.
        - **Strict Boundary Enforcement**: Rented agents operate under locked-down execution policies with restricted tool grants.
        - **Automated Termination**: Leases expire automatically upon task completion to prevent runaway costs.
        """
      }
    ]
  end

  # --- Track 5: Routines & Triggers ---

  defp routines_docs do
    [
      %DocEntry{
        id: "routines-scheduled-routines",
        topic_slug: "routines",
        section_slug: "scheduled-routines",
        title: "Scheduled Routines",
        summary: "Automate recurring background maintenance tasks with Quantum cron expressions.",
        keywords: ["routines", "cron", "quantum", "scheduled", "background tasks"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Recurring Autonomous Operations

        Routines allow companies to schedule repetitive tasks (such as dependency security audits, database cleanups, and weekly release notes) without manual intervention.

        ### Configuring a Routine
        Routines are managed at `/routines`. Each routine consists of:
        - **Assigned Agent**: The agent responsible for executing the routine.
        - **Prompt Template**: The brief executed on each trigger.
        - **Schedule**: Standard 5-field cron expression (e.g. `0 2 * * *` for nightly at 2:00 AM).

        ### Execution Behavior
        When a routine fires, Cympho automatically creates a new issue tagged with the routine identifier, dispatches the assigned agent, and records the run in the company activity stream.
        """
      },
      %DocEntry{
        id: "routines-webhook-triggers",
        topic_slug: "routines",
        section_slug: "webhook-triggers",
        title: "Webhook Triggers",
        summary:
          "Trigger routines from external CI/CD pipelines with HMAC signature verification.",
        keywords: ["webhooks", "triggers", "hmac", "sha256", "replay attack", "tokens"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## Inbound Event-Driven Routines

        In addition to scheduled cron jobs, routines can be triggered by external systems (such as GitHub Actions, Sentry alerts, or internal services) via HTTP POST requests:

        ```
        POST /api/routine-triggers/:public_id/fire
        ```

        ### Replay-Safe HMAC Authentication
        To prevent replay attacks and unauthorized triggers, Cympho verifies cryptographic signatures:
        - **Timestamp Header**: `x-cympho-timestamp` (must be within a 300-second drift window).
        - **Signature Header**: `x-cympho-signature` containing `sha256=<hex>`.

        ### Signature Calculation Example
        ```python
        import hmac, hashlib, time

        timestamp = str(int(time.time()))
        payload = b'{"ref": "refs/heads/main"}'
        signature = hmac.new(
            secret.encode(),
            f"{timestamp}.".encode() + payload,
            hashlib.sha256
        ).hexdigest()
        ```
        """
      },
      %DocEntry{
        id: "routines-run-history",
        topic_slug: "routines",
        section_slug: "run-history",
        title: "Run History & Audits",
        summary: "Inspect historical routine executions, failure reasons, and retry semantics.",
        keywords: ["run history", "audits", "retries", "logs", "execution"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Auditing Routine Performance

        Every routine trigger creates an immutable run record:
        - **Status Tracking**: Inspect whether runs succeeded, failed, or were skipped due to runtime pauses.
        - **Output Artifacts**: Review issues created, token costs, and duration.
        - **Retry Semantics**: If a transient provider error occurs, Cympho retries execution up to three times with exponential backoff before alerting the operator inbox.
        """
      }
    ]
  end

  # --- Track 6: Workspaces & Previews ---

  defp workspaces_docs do
    [
      %DocEntry{
        id: "workspaces-git-worktrees",
        topic_slug: "workspaces",
        section_slug: "git-worktrees",
        title: "Git Worktrees & Isolation",
        summary: "Isolated file checkouts per agent or task to eliminate branch collisions.",
        keywords: ["workspaces", "git worktree", "isolation", "branch", "concurrency"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## Safe Concurrent Code Modifications

        When multiple AI agents write code concurrently in the same repository, modifying a shared working copy leads to race conditions, overwritten files, and broken builds.

        Cympho solves this through **dynamic git worktrees**:
        - Each agent execution session or issue can be assigned a dedicated git worktree.
        - Worktrees are checked out to task-specific branches (e.g. `cympho/feat-auth-middleware-42`).
        - Agents edit, test, and commit strictly within their isolated worktree directory.
        - When work is approved, changes are merged cleanly into the target branch.
        """
      },
      %DocEntry{
        id: "workspaces-runtime-services",
        topic_slug: "workspaces",
        section_slug: "runtime-services",
        title: "Runtime Services & Port Leases",
        summary: "Launch development servers inside workspaces with managed port allocation.",
        keywords: ["services", "ports", "leases", "dev server", "health probes"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Autonomous Development Servers

        Agents can start and manage background services (e.g. Phoenix servers, Vite dev servers, test databases) inside their execution workspace:
        - **Port Lease Manager**: Dynamically allocates unused host ports to avoid port collision errors.
        - **Automated Health Probes**: Periodically pings HTTP endpoints to verify the service is running.
        - **Automatic Teardown**: When the agent session terminates, leased ports and background processes are safely released.
        """
      },
      %DocEntry{
        id: "workspaces-live-previews",
        topic_slug: "workspaces",
        section_slug: "live-previews",
        title: "Live Previews & Security",
        summary: "Secure browser previews for human review with capability tokens.",
        keywords: ["live previews", "preview host", "security", "cookie isolation", "proxy"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## Safe In-Browser Inspection

        Cympho enables operators to visually preview web applications built by agents before merging code:
        - **Preview Proxy**: Routes traffic to the internal workspace port without exposing raw ports to the public internet.
        - **Domain Isolation (`PREVIEW_HOST`)**: Previews run on a dedicated preview domain or isolated hostname boundary. This ensures untrusted agent code cannot access user session cookies or localStorage.
        - **Signed Capability Tokens**: Preview URLs carry short-lived cryptographic capability tokens that expire automatically.
        """
      }
    ]
  end

  # --- Track 7: Governance, Policies & Budgets ---

  defp governance_docs do
    [
      %DocEntry{
        id: "governance-board-approvals",
        topic_slug: "governance",
        section_slug: "board-approvals",
        title: "Board Approvals & Governance",
        summary: "Quorum voting and human authorization gates for high-risk company actions.",
        keywords: ["governance", "board approvals", "voting", "quorum", "high-risk"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## Protecting the Organization

        Certain company operations carry high organizational risk and cannot be executed autonomously by agents or individual members. These operations require **Board Approval**:
        - Adding new agents with executive authority.
        - Raising monthly spend ceilings above predefined thresholds.
        - Exporting or importing company tenant data.
        - Deploying directly to production environments.

        ## Voting & Quorum
        When an approval is requested:
        1. Board members receive notifications in their inbox.
        2. A formal proposal displays the requesting actor, payload, and justification.
        3. Members cast votes (`approve`, `reject`, `abstain`).
        4. Once quorum is reached, the approved action is automatically executed by `Cympho.BoardApprovals.BoardApprovalActionExecutor`.
        """
      },
      %DocEntry{
        id: "governance-execution-policies",
        topic_slug: "governance",
        section_slug: "execution-policies",
        title: "Execution Policies",
        summary:
          "Granular restrictions on allowed tools, dangerous commands, and token consumption.",
        keywords: ["execution policies", "security", "tool restrictions", "guardrails", "limits"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Guardrails & Constraint Boundaries

        Execution policies define what agents are permitted to do during an execution run:
        - **Tool Whitelists**: Limit the MCP tools an agent can invoke (e.g. read-only queries vs. mutating issues).
        - **Command Sandboxing**: Block dangerous terminal commands (e.g. `rm -rf`, raw database drops).
        - **Step Limits**: Prevent infinite loops by enforcing a maximum number of autonomous steps per session.
        - **Inheritance**: Policies can be defined company-wide, per project, or per agent.
        """
      },
      %DocEntry{
        id: "governance-spend-tracking",
        topic_slug: "governance",
        section_slug: "spend-tracking",
        title: "Spend Tracking & Budgets",
        summary: "Monitor AI provider costs, set budget limits, and configure proactive alerts.",
        keywords: ["spend tracking", "budgets", "costs", "tokens", "alerts"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Real-Time Cost Observability

        Cympho tracks token consumption and monetary spend across every agent run:
        - **Breakdown by Agent & Model**: View which agents and models consume the greatest share of budget.
        - **Budget Ceilings**: Set monthly or per-project dollar caps.
        - **Threshold Alerts**: Automatic warnings fire at 80% and 100% of allocated budget.
        - **Auto-Throttling**: When a budget ceiling is exceeded, Cympho transitions the company to Low Power or Paused mode to prevent surprise invoices.

        ### USD Hard Stops Need a Known Price
        A hard stop can only count what Cympho can price. While one applies to a run, Cympho refuses to start a runtime whose cost it cannot work out:
        - **Reports a cost** (Claude Code): counted as reported.
        - **Reports tokens only** (Codex, OpenAI chat): needs USD rates for the agent's model, or flat rate.
        - **Reports no usage** (Cursor, HTTP, OpenClaw, Agrenting, generic process commands): needs flat rate.

        Set both on the agent's **Configuration** tab, under **Billing**: choose Metered or Flat rate, and enter input, output, and cached-input USD per million tokens for the current model (set a model first). Flat rate covers only the agent's own runtime, never a fallback runtime. A refused issue stays queued, no run starts, and the agent is not paused. The **Spending limit** readiness item says why, and the dispatcher retries the issue with a growing delay until the agent can be priced.
        """
      },
      %DocEntry{
        id: "governance-decision-reversals",
        topic_slug: "governance",
        section_slug: "decision-reversals",
        title: "Decision Reversals",
        summary: "Immutable decision events with atomic, audited rollback mechanisms.",
        keywords: ["decisions", "reversals", "rollback", "audit", "governance"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## Reversible Governance Actions

        Autonomous decisions made by agents or operators are stored as structured decision records in `Cympho.Decisions`:
        - Each decision captures the decision type, outcome, rationale, and affected resources.
        - Decisions marked as `reversible` can be rolled back with one click from the governance dashboard.
        - Rolling back a decision produces a compensatory audit event, preserving a complete, unbroken history of what occurred.
        """
      },
      %DocEntry{
        id: "governance-audit-trails",
        topic_slug: "governance",
        section_slug: "audit-trails",
        title: "Audit Trails & Principal Permissions",
        summary:
          "Tamper-evident logs, cryptographic hash chains, and principal permission checks.",
        keywords: [
          "audit trails",
          "hash chain",
          "principal permissions",
          "security",
          "provenance"
        ],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## Cryptographic Audit Logging

        Security-critical actions in Cympho are recorded to `Cympho.GovernanceAuditLogs`:
        - **Cryptographic Chaining**: Audit log entries are linked using SHA-256 hash chains, ensuring post-hoc tampering or database deletions are immediately detectable.
        - **Actor Attribution**: Records whether the mutation was initiated by a human user, an agent JWT, or an API key.
        - **Principal Permissions**: Fine-grained capability checks verify that the invoking actor possessed explicit authority for the operation.
        """
      }
    ]
  end

  # --- Track 8: MCP & API Reference ---

  defp mcp_api_docs do
    [
      %DocEntry{
        id: "mcp-api-mcp-overview",
        topic_slug: "mcp-api",
        section_slug: "mcp-overview",
        title: "Model Context Protocol (MCP) Overview",
        summary:
          "Architecture, authentication, and security model of Cympho's native MCP server.",
        keywords: ["mcp", "model context protocol", "api", "architecture", "agent authentication"],
        reading_time_minutes: 4,
        last_updated: "October 2026",
        markdown_content: """
        ## The Model Context Protocol in Cympho

        Cympho implements a native [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server at `/api/mcp`. This interface allows external AI agents, autonomous models, and developer tools (Claude Code, Cursor, Codex, CLI harnesses) to discover and execute company tools through a standardized protocol.

        ## Authentication & Multi-Tenancy

        Every MCP request requires an authenticated agent:
        1. **Bearer Token (JWT)**: `Authorization: Bearer <agent_jwt_token>` (used for orchestrated runs).
        2. **API Key**: `X-API-Key: <agent_api_key>` (used for persistent external harnesses).

        ### Zero Cross-Tenant Leakage
        The server extracts the calling agent's `company_id` directly from its verified credentials. Payloads cannot specify or override `company_id`. All database queries and operations are strictly scoped to the agent's tenant.

        ## Primary Endpoints
        - `GET /api/mcp/tools`: Lists all available tools for the calling agent (9 built-in static tools plus allowed dynamic plugin tools).
        - `POST /api/mcp/call`: Executes a tool with arguments on behalf of the agent.
        """
      },
      %DocEntry{
        id: "mcp-api-mcp-tools",
        topic_slug: "mcp-api",
        section_slug: "mcp-tools",
        title: "MCP Built-In Tools Reference",
        summary:
          "Complete input schemas and return contracts for all 9 built-in static MCP tools.",
        keywords: [
          "mcp tools",
          "list_issues",
          "get_issue",
          "create_issue",
          "create_issue_comment",
          "search",
          "list_agents",
          "list_projects",
          "get_kanban_state",
          "list_issue_comments"
        ],
        reading_time_minutes: 6,
        last_updated: "October 2026",
        markdown_content: """
        ## Built-In Static Tools

        Cympho ships with 9 core MCP tools built directly into `Cympho.Mcp.Server`:

        | Tool | Purpose | Access |
        |---|---|---|
        | `list_issues` | Query and filter company issues | Read |
        | `get_issue` | Retrieve detailed issue view with recent comments | Read |
        | `list_issue_comments` | Retrieve chronological comment history | Read |
        | `create_issue_comment` | Post a comment on an issue | Write (Governed) |
        | `create_issue` | Create a new task or issue | Write (Governed) |
        | `list_projects` | List active projects and prefixes | Read |
        | `list_agents` | List company agents, roles, and status | Read |
        | `get_kanban_state` | Summarize kanban columns and issue counts | Read |
        | `search` | Full-text search across issues and comments | Read |

        ---

        ### 1. `list_issues`
        Query company issues with optional status, priority, role, and text filtering.

        #### Parameters
        - `status` *(string)*: `backlog`, `todo`, `in_progress`, `in_review`, `done`, `blocked`
        - `priority` *(string)*: `critical`, `high`, `medium`, `low`
        - `assignee_id` *(string)*: Filter by assigned agent ID
        - `assigned_role` *(string)*: Filter by assigned role
        - `project_id` *(string)*: Filter by project UUID
        - `search` *(string)*: Query string for title/description matching
        - `limit` *(integer, default 20)*: Maximum items to return

        ---

        ### 2. `get_issue`
        Retrieve detailed issue attributes, assignment, and recent comments.

        #### Parameters
        - `issue_id` *(string, required)*: The UUID of the issue

        ---

        ### 3. `list_issue_comments`
        Retrieve chronological comments for a specific issue.

        #### Parameters
        - `issue_id` *(string, required)*: The UUID of the issue
        - `limit` *(integer, default 20)*: Maximum comments to return

        ---

        ### 4. `create_issue_comment`
        Post an agent comment on an issue.

        #### Parameters
        - `issue_id` *(string, required)*: Target issue UUID
        - `body` *(string, required)*: Comment body text

        *Authority check: Requires CEO/CTO role, assignment to the issue, or explicit comment permissions.*

        ---

        ### 5. `create_issue`
        Create a new task or issue within a project.

        #### Parameters
        - `title` *(string, required)*: Clear title for the issue
        - `description` *(string)*: Detailed brief and acceptance criteria
        - `priority` *(string, default "medium")*: `critical`, `high`, `medium`, `low`
        - `project_id` *(string)*: Owning project UUID
        - `assigned_role` *(string)*: Role to assign (`ceo`, `cto`, `engineer`, `designer`, etc.)
        - `assignee_id` *(string)*: Specific agent ID to assign

        ---

        ### 6. `list_projects`
        List all company projects and issue prefixes. Takes no required parameters.

        ---

        ### 7. `list_agents`
        List all agents in the company, optionally filtered by `status` (`idle`, `busy`, `paused`).

        ---

        ### 8. `get_kanban_state`
        Retrieve kanban board columns with active issue counts and cards, optionally filtered by `project_id`.

        ---

        ### 9. `search`
        Execute full-text keyword search across issues and comments.

        #### Parameters
        - `query` *(string, required)*: Search keywords
        """
      },
      %DocEntry{
        id: "mcp-api-dynamic-tools",
        topic_slug: "mcp-api",
        section_slug: "dynamic-tools",
        title: "Dynamic Plugin Tools",
        summary: "Extensible tool registry, grant authorization, and timeout protections.",
        keywords: ["dynamic tools", "plugins", "tool registry", "grants", "timeout"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Extensible Plugin Tooling

        In addition to static built-in tools, installed Cympho plugins can register dynamic tools via `Cympho.Mcp.ToolRegistry`:
        - **Fail-Closed Grants**: Dynamic tools are hidden by default. Agents must receive explicit grants to view or call them.
        - **Execution Safety**: Dynamic tools execute through monitored GenServers with a default 30-second timeout.
        - **Audit Logging**: Dynamic tool calls are traced in `Cympho.ToolCallTraces` alongside static tools.
        """
      },
      %DocEntry{
        id: "mcp-api-rest-api",
        topic_slug: "mcp-api",
        section_slug: "rest-api",
        title: "REST API Reference",
        summary:
          "HTTP JSON endpoints for user authentication, issues, goals, routines, and workspaces.",
        keywords: ["rest api", "json", "endpoints", "curl", "http"],
        reading_time_minutes: 5,
        last_updated: "October 2026",
        markdown_content: """
        ## Cympho REST API

        Cympho exposes a comprehensive JSON API at `/api`:

        ### Base URLs
        - Development: `http://localhost:4329/api`
        - Production: `https://cympho.llmotions.com/api`

        ### Core Endpoints

        #### Authentication
        - `POST /api/login`: Authenticate user credentials and receive a JWT.
        - `POST /api/register`: Register a new user account.

        #### Issues & Work Products
        - `GET /api/issues`: List company issues with filtering.
        - `POST /api/issues`: Create a new issue.
        - `GET /api/issues/:id`: Retrieve issue detail.
        - `POST /api/issues/:id/work-products`: Attach a code patch or deliverable.

        #### Routines & Approvals
        - `GET /api/routines`: List scheduled routines.
        - `POST /api/routines/:id/run`: Trigger an immediate routine run.
        - `GET /api/approvals`: List governance approval requests.
        - `PATCH /api/approvals/:id`: Resolve an approval (`approved` or `denied`).
        """
      },
      %DocEntry{
        id: "mcp-api-webhooks",
        topic_slug: "mcp-api",
        section_slug: "webhooks",
        title: "Inbound Webhooks & Alerts",
        summary: "Integrate GitHub webhooks, Telegram alerts, and custom automation events.",
        keywords: ["webhooks", "github", "telegram", "signatures", "integrations"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## External Event Integrations

        ### GitHub Webhooks
        Cympho receives pull request and commit events at `/api/github/webhook`:
        - Verified using GitHub HMAC signatures (`X-Hub-Signature-256`).
        - Automatically transitions linked issues to `in_review` when a pull request is opened.
        - Automatically marks issues `done` when the pull request is merged.

        ### Telegram Notifications
        Configure the Telegram bot webhook to receive instant push alerts when board approvals require immediate attention.
        """
      },
      %DocEntry{
        id: "mcp-api-telemetry-beam",
        topic_slug: "mcp-api",
        section_slug: "telemetry-beam",
        title: "BEAM Telemetry & Tool Traces",
        summary: "Inspect BEAM processes, ETS tables, and cryptographic tool-call traces.",
        keywords: ["beam", "telemetry", "livedashboard", "tool traces", "crypto"],
        reading_time_minutes: 3,
        last_updated: "October 2026",
        markdown_content: """
        ## Deep System Observability

        ### BEAM Introspection at `/beam`
        In Advanced Mode, operators can access the live Phoenix LiveDashboard at `/beam` to monitor:
        - Erlang VM memory distribution, process queues, and reductions.
        - Supervision trees and dynamic agent heartbeat supervisors.
        - ETS event replay caches and rate-limiter buckets.

        ### Cryptographic Tool-Call Tracing
        Every MCP tool execution is recorded in `Cympho.ToolCallTraces` at `/tool-call-traces`. Traces are anchored in a cryptographic hash chain, allowing verification that logs have not been manipulated.
        """
      }
    ]
  end
end
