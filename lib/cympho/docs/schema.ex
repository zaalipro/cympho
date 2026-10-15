defmodule Cympho.Docs.Schema do
  @moduledoc """
  Data model structures for Cympho's in-app documentation hub.
  """
end

defmodule Cympho.Docs.Topic do
  @moduledoc """
  Represents a top-level documentation track (e.g. Getting Started, AI Agents).
  """
  @enforce_keys [:slug, :title]
  defstruct [
    :id,
    :slug,
    :title,
    :summary,
    :icon,
    :order,
    sections: []
  ]
end

defmodule Cympho.Docs.Section do
  @moduledoc """
  Represents a document section under a topic (e.g. Swarm Mode under AI Agents).
  """
  @enforce_keys [:slug, :title, :topic_slug]
  defstruct [
    :id,
    :slug,
    :title,
    :summary,
    :topic_slug,
    :order
  ]
end

defmodule Cympho.Docs.DocEntry do
  @moduledoc """
  Represents an individual documentation article with metadata, content, and navigation links.
  """
  @enforce_keys [:topic_slug, :section_slug, :title]
  defstruct [
    :id,
    :topic_slug,
    :section_slug,
    :title,
    :summary,
    keywords: [],
    reading_time_minutes: 3,
    last_updated: "October 2026",
    markdown_content: "",
    html_content: nil,
    anchors: [],
    prev_doc: nil,
    next_doc: nil
  ]
end
