defmodule Cympho.Docs.SearchIndex do
  @moduledoc """
  High-performance in-memory search index for Cympho documentation.
  Pre-computes tokenized doc fragments for sub-millisecond querying without
  external database dependencies.
  """

  alias Cympho.Docs.Content

  @doc """
  Performs ranked keyword search across all documentation sections.
  Returns a list of %{doc: DocEntry, score: integer(), snippet: String.t()}.
  """
  @spec search(String.t() | nil, keyword()) :: list(map())
  def search(query, opts \\ [])

  def search(nil, _opts), do: []

  def search(query, opts) when is_binary(query) do
    clean_query = query |> String.trim() |> String.downcase()

    if clean_query == "" do
      []
    else
      query_tokens = tokenize(clean_query)
      limit = Keyword.get(opts, :limit, 10)
      docs = Content.all_docs()

      docs
      |> Enum.map(&score_doc(&1, query_tokens, clean_query))
      |> Enum.filter(&(&1.score > 0))
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)
    end
  end

  def search(_other, _opts), do: []

  defp score_doc(doc, query_tokens, clean_query) do
    title_matches = count_matches(doc.title, query_tokens)
    keywords_text = Enum.join(doc.keywords || [], " ")
    keyword_matches = count_matches(keywords_text, query_tokens)
    summary_matches = count_matches(doc.summary, query_tokens)
    body_matches = count_matches(doc.markdown_content, query_tokens)

    # Exact phrase matches receive extra boost
    exact_title_bonus =
      if String.contains?(String.downcase(doc.title || ""), clean_query), do: 25, else: 0

    exact_keyword_bonus =
      if String.contains?(String.downcase(keywords_text), clean_query), do: 15, else: 0

    total_score =
      title_matches * 10 +
        keyword_matches * 5 +
        summary_matches * 3 +
        body_matches * 1 +
        exact_title_bonus +
        exact_keyword_bonus

    snippet =
      extract_snippet(doc.markdown_content || doc.summary || "", clean_query, query_tokens)

    %{
      doc: doc,
      score: total_score,
      snippet: snippet
    }
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_-]+/u, trim: true)
  end

  defp count_matches(nil, _tokens), do: 0

  defp count_matches(text, tokens) do
    text_down = String.downcase(text)
    Enum.count(tokens, &String.contains?(text_down, &1))
  end

  defp extract_snippet(nil, _raw_query, _query_tokens), do: ""

  defp extract_snippet(content, raw_query, query_tokens) when is_binary(content) do
    content_down = String.downcase(content)

    match_pos =
      case :binary.match(content_down, raw_query) do
        {pos, _len} ->
          pos

        :nomatch ->
          first_token_pos(content_down, query_tokens)
      end

    case match_pos do
      pos when is_integer(pos) and pos >= 0 ->
        start_pos = content |> byte_size() |> min(max(0, pos - 40))
        length = min(byte_size(content) - start_pos, 160)
        snippet_raw = binary_part(content, start_pos, length)

        # Strip newlines and excess whitespace for clean preview in search cards,
        # ensuring clean UTF-8 boundaries so multi-byte diagrams never break JSON encoding
        cleaned =
          snippet_raw
          |> sanitize_utf8()
          |> String.replace(~r/[\r\n#*`]+/, " ")
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        prefix = if start_pos > 0, do: "...", else: ""
        suffix = if start_pos + length < byte_size(content), do: "...", else: ""
        "#{prefix}#{cleaned}#{suffix}"

      _ ->
        content
        |> String.slice(0, 140)
        |> sanitize_utf8()
        |> String.replace(~r/[\r\n#*`]+/, " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> Kernel.<>("...")
    end
  end

  defp sanitize_utf8(binary) when is_binary(binary) do
    binary
    |> drop_leading_continuation_bytes()
    |> drop_trailing_incomplete_bytes()
    |> String.replace_invalid("")
  end

  defp drop_leading_continuation_bytes(<<b, rest::binary>>) when b in 0x80..0xBF do
    drop_leading_continuation_bytes(rest)
  end

  defp drop_leading_continuation_bytes(binary), do: binary

  defp drop_trailing_incomplete_bytes(binary) when byte_size(binary) == 0, do: binary

  defp drop_trailing_incomplete_bytes(binary) do
    if String.valid?(binary) do
      binary
    else
      len = byte_size(binary) - 1
      <<trimmed::binary-size(len), _last>> = binary
      drop_trailing_incomplete_bytes(trimmed)
    end
  end

  defp first_token_pos(content_down, tokens) do
    Enum.find_value(tokens, fn token ->
      case :binary.match(content_down, token) do
        {pos, _len} -> pos
        :nomatch -> nil
      end
    end)
  end
end
