defmodule Cympho.Adapters.OutputLimit do
  @moduledoc false

  @ceiling min(
             Application.compile_env(:cympho, :agent_runner_max_output_bytes, 8_000_000),
             8_000_000
           )
  @tail_bytes 8_192

  def effective(opts, config) do
    [value(opts), value(config), @ceiling]
    |> Enum.reject(&is_nil/1)
    |> Enum.min()
  end

  def tail(acc, data) do
    data_size = byte_size(data)

    if data_size >= @tail_bytes do
      data
      |> binary_part(data_size - @tail_bytes, @tail_bytes)
      |> :binary.copy()
    else
      retained = min(byte_size(acc), @tail_bytes - data_size)
      binary_part(acc, byte_size(acc) - retained, retained) <> data
    end
  end

  # The relay stops after limit + 1 bytes. The extra byte lets the receive
  # loop distinguish an exact-limit success from a truncated structured result.
  # It also prevents unbounded port messages if the child floods stdout.
  def wrapped_command(command, args, limit, prompt_file? \\ false) do
    bash = System.find_executable("bash") || "/bin/bash"
    input = if prompt_file?, do: ~s( < "$CYMPHO_PROMPT_FILE"), else: ""

    script =
      case limiter(limit + 1) do
        :unavailable ->
          "printf 'output limiter requires perl or python3\\n' >&2; exit 127"

        relay ->
          "\"$@\"#{input} 2>&1 | #{relay}; statuses=(\"${PIPESTATUS[@]}\"); " <>
            "if [ \"${statuses[1]}\" -ne 0 ]; then exit \"${statuses[1]}\"; fi; " <>
            "exit \"${statuses[0]}\""
      end

    {bash, ["-c", script, "cympho-output-limit", to_string(command) | args]}
  end

  defp value(opts) when is_list(opts), do: opts |> Keyword.get(:max_output_bytes) |> positive()

  defp value(config) when is_map(config) do
    config
    |> Map.get(:max_output_bytes, Map.get(config, "max_output_bytes"))
    |> positive()
  end

  defp value(_), do: nil

  defp positive(n) when is_integer(n) and n > 0, do: n

  defp positive(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp positive(_), do: nil

  defp limiter(limit) do
    case System.find_executable("perl") do
      perl when is_binary(perl) ->
        program =
          "$r=shift; while($r>0){$w=$r<65536?$r:65536;" <>
            "$n=sysread(STDIN,$b,$w); last unless $n; $o=0;" <>
            "while($o<$n){$x=syswrite(STDOUT,$b,$n-$o,$o); exit 1 unless $x; $o+=$x;}" <>
            "$r-=$n;}"

        Enum.map_join([perl, "-e", program, Integer.to_string(limit)], " ", &quote_arg/1)

      _ ->
        case System.find_executable("python3") do
          python when is_binary(python) ->
            program =
              "import os,sys\n" <>
                "remaining=int(sys.argv[1])\n" <>
                "while remaining:\n" <>
                " data=os.read(0,min(65536,remaining))\n" <>
                " if not data: break\n" <>
                " remaining-=len(data)\n" <>
                " while data:\n" <>
                "  written=os.write(1,data)\n" <>
                "  data=data[written:]\n"

            Enum.map_join(
              [python, "-u", "-c", program, Integer.to_string(limit)],
              " ",
              &quote_arg/1
            )

          _ ->
            :unavailable
        end
    end
  end

  defp quote_arg(arg), do: "'" <> String.replace(arg, "'", "'\"'\"'") <> "'"
end
