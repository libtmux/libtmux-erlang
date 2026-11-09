defmodule CrossPortProbe do
  alias LibTmux.{Filter, Schema, Selection, Snapshot}

  @entities %{
    "session" => :session,
    "window" => :window,
    "windowLink" => :window_link,
    "pane" => :pane
  }

  def native_row(entity, document) do
    {:ok, schema} = :tmux_schema.fields(entity)

    values =
      Enum.reduce(schema, %{}, fn {name, metadata}, acc ->
        case Map.fetch(document, metadata.wire) do
          :error ->
            acc

          {:ok, value} ->
            decoded =
              case {metadata.type, value} do
                {:bytes, %{"base64" => bytes}} -> Base.decode64!(bytes)
                {_, :null} -> :none
                _ -> value
              end

            Map.put(acc, name, decoded)
        end
      end)

    unless map_size(values) == map_size(document),
      do: raise(ArgumentError, "native fixture has an unknown field")

    {:ok, row} = :tmux_model.new(entity, values)
    row
  end

  def native_snapshot(graph) do
    tables =
      Map.new(@entities, fn {wire, entity} ->
        {entity, Enum.map(Map.fetch!(graph, wire), &native_row(entity, &1))}
      end)

    {:ok, snapshot} =
      :tmux_snapshot.build(
        tables,
        %{
          origin: make_ref(),
          id: make_ref(),
          generation: make_ref(),
          graph: :complete
        }
      )

    snapshot
  end

  def companion_rows(graph, omitted) do
    for entity <- Schema.entities(), into: %{} do
      wire =
        Enum.find_value(@entities, fn {wire, type} ->
          if entity == type, do: wire
        end)

      rows =
        for document <- Map.get(graph, wire, []) do
          known =
            MapSet.new(Schema.fields(entity), fn {_, meta} -> meta.wire end)

          unless Enum.all?(Map.keys(document), &MapSet.member?(known, &1)),
            do: raise(ArgumentError, "companion fixture has an unknown field")

          for {name, metadata} <- Schema.fields(entity),
              Map.has_key?(document, metadata.wire),
              {entity, name} not in omitted,
              into: %{} do
            value = document[metadata.wire]

            value =
              case value do
                %{"base64" => bytes} -> Base.decode64!(bytes)
                _ -> value
              end

            {name, value}
          end
        end

      {entity, rows}
    end
  end

  def companion_snapshot(graph, omitted) do
    rows = companion_rows(graph, omitted)

    fields =
      Map.new(rows, fn {entity, values} ->
        {entity, Enum.uniq([:id | Enum.flat_map(values, &Map.keys/1)])}
      end)

    Snapshot.new(rows,
      server_instance: "conformance",
      captured_from: 0,
      captured_until: 0,
      fields: fields,
      complete: Schema.entities()
    )
  end

  def ids(:erlang, snapshot, entity, filter) do
    selection = apply(:tmux_select, entity_fun(entity), [snapshot])
    selection = :tmux_select.where(filter, selection)
    Enum.map(:tmux_select.to_list(selection), &:tmux_model.get(:id, &1))
  end

  def ids(:elixir, snapshot, entity, filter) do
    snapshot
    |> Selection.new(entity)
    |> Selection.where(filter)
    |> Enum.map(& &1.id)
  end

  def entity_fun(:session), do: :sessions
  def entity_fun(:window), do: :windows
  def entity_fun(:window_link), do: :window_links
  def entity_fun(:pane), do: :panes

  def error(%LibTmux.Error{} = detail) do
    code =
      case detail.details[:code] do
        nil -> nil
        value -> to_string(value)
      end

    %{
      "kind" => Atom.to_string(detail.kind),
      "code" => code,
      "path" => Enum.map(detail.path, &path_item/1)
    }
  end

  def error(detail) when is_map(detail) do
    %{
      "code" => to_string(detail[:code]),
      "path" => Enum.map(detail[:path] || [], &path_item/1)
    }
  end

  def path_item(item) when is_atom(item), do: Atom.to_string(item)
  def path_item(item), do: item

  def run_case(port, case_data, snapshot) do
    document = case_data["filter"]
    entity = Map.fetch!(@entities, document["entity"])

    constructor =
      if port == :erlang,
        do: &:tmux_filter.from_wire/2,
        else: &Filter.from_wire/2

    base = %{"name" => case_data["name"], "entity" => document["entity"]}

    case constructor.(entity, document) do
      {:ok, filter} ->
        try do
          actual = ids(port, snapshot, entity, filter)

          Map.merge(base, %{
            "admitted" => true,
            "actual" => actual,
            "expected" => case_data["expected"],
            "semantic_match" => actual == case_data["expected"]
          })
        rescue
          failure in LibTmux.Error ->
            Map.merge(base, %{
              "admitted" => true,
              "evaluation_error" => error(failure)
            })
        end

      {:error, detail} ->
        Map.merge(base, %{"admitted" => false, "error" => error(detail)})
    end
  end

  def invalid_case(port, case_data) do
    document = case_data["filter"]
    entity = Map.fetch!(@entities, document["entity"])

    constructor =
      if port == :erlang,
        do: &:tmux_filter.from_wire/2,
        else: &Filter.from_wire/2

    result =
      case constructor.(entity, document) do
        {:ok, _} ->
          %{"rejected" => false}

        {:error, detail} ->
          actual = error(detail)

          %{
            "rejected" => true,
            "error" => actual,
            "matches_erlang_diagnostic" =>
              actual["code"] == case_data["code"] and
                actual["path"] == case_data["path"]
          }
      end

    Map.merge(
      %{
        "name" => case_data["name"],
        "expected_code" => case_data["code"],
        "expected_path" => case_data["path"]
      },
      result
    )
  end

  def run(fixture_path, output) do
    raw = File.read!(fixture_path)
    {:ok, native_data} = :tmux_json.decode(raw)
    {:ok, companion_data} = LibTmux.Wire.decode(raw)
    native = native_snapshot(native_data["graph"])
    full = companion_snapshot(companion_data["graph"], [])

    full_result =
      case full do
        {:ok, _} -> %{"accepted" => true}
        {:error, failure} -> %{"accepted" => false, "error" => error(failure)}
      end

    # Keep the rejected full graph visible alongside the narrower comparison.
    {projected, omitted} =
      case full do
        {:ok, snapshot} ->
          {snapshot, []}

        {:error, _} ->
          {:ok, snapshot} =
            companion_snapshot(companion_data["graph"], [{:pane, :current_path}])

          {snapshot, ["pane.currentPath"]}
      end

    otp_file =
      Path.join([
        to_string(:code.root_dir()),
        "releases",
        System.otp_release(),
        "OTP_VERSION"
      ])

    beam_digest = fn module ->
      module
      |> :code.which()
      |> to_string()
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end

    results = %{
      "fixture" => fixture_path,
      "runtime" => %{
        "otp" => String.trim(File.read!(otp_file)),
        "erts" => to_string(:erlang.system_info(:version)),
        "elixir" => System.version(),
        "erlang_filter_beam" => to_string(:code.which(:tmux_filter)),
        "elixir_filter_beam" => to_string(:code.which(LibTmux.Filter)),
        "erlang_filter_beam_sha256" => beam_digest.(:tmux_filter),
        "elixir_filter_beam_sha256" => beam_digest.(LibTmux.Filter)
      },
      "fixture_construction" => %{
        "erlang" => "internal tmux_snapshot:build/2 test fixture boundary",
        "elixir" => "public LibTmux.Snapshot.new/2"
      },
      "erlang" => %{
        "valid" =>
          Enum.map(native_data["cases"], &run_case(:erlang, &1, native)),
        "invalid" =>
          Enum.map(native_data["invalid"], &invalid_case(:erlang, &1))
      },
      "elixir" => %{
        "full_graph" => full_result,
        "semantic_graph_profile" =>
          if(omitted == [],
            do: "full fixture",
            else:
              "original topology; pane.currentPath omitted and left unloaded"
          ),
        "omitted_fields" => omitted,
        "wire_translation" => false,
        "valid" =>
          Enum.map(companion_data["cases"], &run_case(:elixir, &1, projected)),
        "invalid" =>
          Enum.map(companion_data["invalid"], &invalid_case(:elixir, &1))
      }
    }

    File.write!(output, JSON.encode!(results))
    IO.puts("wrote public-API conformance observations")
  end
end

[fixture, output] = System.argv()
CrossPortProbe.run(fixture, output)
