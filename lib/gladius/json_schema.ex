defmodule Gladius.JsonSchema do
  @moduledoc """
  Converts Gladius specs and schemas to JSON Schema (draft 2020-12) maps.

  Used via `Gladius.Schema.to_json_schema/2`.

  ## Mapping rules

  | Gladius spec               | JSON Schema                                          |
  |----------------------------|------------------------------------------------------|
  | `string()`                 | `{"type": "string"}`                                 |
  | `string(:filled?)`         | `{"type": "string", "minLength": 1}`                 |
  | `string(format: ~r/re/)`   | `{"type": "string", "pattern": "re"}`                |
  | `integer(gte?: 0)`         | `{"type": "integer", "minimum": 0}`                  |
  | `integer(gt?: 0)`          | `{"type": "integer", "exclusiveMinimum": 0}`         |
  | `integer(in?: [1,2,3])`    | `{"enum": [1, 2, 3]}`                                |
  | `float()` / `number()`     | `{"type": "number"}`                                 |
  | `boolean()`                | `{"type": "boolean"}`                                |
  | `atom()`                   | `{"type": "string"}`                                 |
  | `atom(in?: [:a, :b])`      | `{"enum": ["a", "b"]}`                               |
  | `nil_spec()`               | `{"type": "null"}`                                   |
  | `any()`                    | `{}`                                                 |
  | `map()`                    | `{"type": "object"}`                                 |
  | `list()`                   | `{"type": "array"}`                                  |
  | `list_of(inner)`           | `{"type": "array", "items": inner}`                  |
  | `maybe(inner)`             | `{"oneOf": [{"type": "null"}, inner]}`               |
  | `all_of([s1, s2])`         | `{"allOf": [s1, s2]}`                                |
  | `any_of([s1, s2])`         | `{"anyOf": [s1, s2]}`                                |
  | `not_spec(inner)`          | `{"not": inner}`                                     |
  | `default(inner, val)`      | inner + `"default": val`                             |
  | `transform(inner, _)`      | inner (transform is invisible to JSON Schema)        |
  | `coerce(inner, _)`         | inner (output type; coercion is a runtime concern)   |
  | `validate(inner, _)`       | inner (cross-field rules have no JSON Schema form)   |
  | `ref(:name)`               | resolved and inlined                                 |
  | `schema(%{...})`           | `{"type": "object", "properties": {...}, ...}`       |
  | `open_schema(%{...})`      | same with `"additionalProperties": true`             |
  | `spec(pred)`               | `{"description": "custom predicate — ..."}` (note B) |

  ## Lossiness

  Some Gladius features have no JSON Schema equivalent:

  - `transform/2` — the transform function is omitted; only the input spec is emitted
  - `coerce/2` — the coercion is omitted; the *output* type spec is emitted
  - `validate/2` — cross-field rules are omitted; only the inner schema is emitted
  - `spec(pred)` — arbitrary predicates emit `{"description": "custom predicate..."}`
  - `cond_spec/3` — emits `{"description": "conditional spec — ..."}`
  """

  alias Gladius.{
    Spec, All, Any, Not, Maybe, Ref, ListOf, Cond,
    Schema, SchemaKey, Default, Transform, Validate
  }

  @draft_uri "https://json-schema.org/draft/2020-12/schema"

  @doc """
  Converts a Gladius conformable to a JSON Schema map.

  ## Options

    * `:title` — adds a `"title"` field to the root object
    * `:description` — adds a `"description"` field to the root object
    * `:schema_header` — include the `"$schema"` URI (default: `true`)

  ## Example

      import Gladius

      address = schema(%{
        required(:street) => string(:filled?),
        required(:zip)    => string(size?: 5)
      })

      user = schema(%{
        required(:name)    => string(:filled?),
        required(:age)     => integer(gte?: 0),
        optional(:role)    => atom(in?: [:admin, :user]),
        optional(:address) => address
      })

      Gladius.Schema.to_json_schema(user, title: "User")
      #=> %{
      #=>   "$schema" => "https://json-schema.org/draft/2020-12/schema",
      #=>   "title"   => "User",
      #=>   "type"    => "object",
      #=>   "properties" => %{
      #=>     "name"    => %{"type" => "string", "minLength" => 1},
      #=>     "age"     => %{"type" => "integer", "minimum" => 0},
      #=>     "role"    => %{"enum" => ["admin", "user"]},
      #=>     "address" => %{
      #=>       "type" => "object",
      #=>       "properties" => %{
      #=>         "street" => %{"type" => "string", "minLength" => 1},
      #=>         "zip"    => %{"type" => "string", "minLength" => 5, "maxLength" => 5}
      #=>       },
      #=>       "required"             => ["street", "zip"],
      #=>       "additionalProperties" => false
      #=>     }
      #=>   },
      #=>   "required"             => ["name", "age"],
      #=>   "additionalProperties" => false
      #=> }
  """
  @spec convert(Gladius.conformable(), keyword()) :: map()
  def convert(conformable, opts \\ []) do
    base = to_json_schema(conformable)

    base
    |> maybe_put("title", Keyword.get(opts, :title))
    |> maybe_put("description", Keyword.get(opts, :description))
    |> then(fn schema ->
      if Keyword.get(opts, :schema_header, true) do
        Map.put(schema, "$schema", @draft_uri)
      else
        schema
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Primitives
  # ---------------------------------------------------------------------------

  defp to_json_schema(%Spec{type: :string, constraints: cs}) do
    %{"type" => "string"}
    |> apply_string_constraints(cs)
  end

  defp to_json_schema(%Spec{type: :integer, constraints: cs}) do
    in_values = Keyword.get(cs, :in?)

    if in_values do
      %{"enum" => in_values}
    else
      %{"type" => "integer"}
      |> apply_numeric_constraints(cs)
    end
  end

  defp to_json_schema(%Spec{type: type, constraints: cs})
       when type in [:float, :number] do
    %{"type" => "number"}
    |> apply_numeric_constraints(cs)
  end

  defp to_json_schema(%Spec{type: :boolean}), do: %{"type" => "boolean"}
  defp to_json_schema(%Spec{type: :null}),    do: %{"type" => "null"}
  defp to_json_schema(%Spec{type: :map}),     do: %{"type" => "object"}
  defp to_json_schema(%Spec{type: :list}),    do: %{"type" => "array"}
  defp to_json_schema(%Spec{type: :any}),     do: %{}

  defp to_json_schema(%Spec{type: :atom, constraints: cs}) do
    case Keyword.get(cs, :in?) do
      nil    -> %{"type" => "string"}
      values -> %{"enum" => Enum.map(values, &Atom.to_string/1)}
    end
  end

  # Predicate-only spec — no JSON Schema equivalent
  defp to_json_schema(%Spec{type: nil, predicate: pred}) when not is_nil(pred) do
    %{"description" => "custom predicate — no JSON Schema equivalent"}
  end

  # Empty spec
  defp to_json_schema(%Spec{type: nil, predicate: nil}), do: %{}

  # ---------------------------------------------------------------------------
  # Combinators
  # ---------------------------------------------------------------------------

  defp to_json_schema(%All{specs: []}), do: %{}

  defp to_json_schema(%All{specs: specs}) do
    %{"allOf" => Enum.map(specs, &to_json_schema/1)}
  end

  defp to_json_schema(%Any{specs: []}), do: %{}

  defp to_json_schema(%Any{specs: specs}) do
    %{"anyOf" => Enum.map(specs, &to_json_schema/1)}
  end

  defp to_json_schema(%Not{spec: inner}) do
    %{"not" => to_json_schema(inner)}
  end

  defp to_json_schema(%Maybe{spec: inner}) do
    %{"oneOf" => [%{"type" => "null"}, to_json_schema(inner)]}
  end

  defp to_json_schema(%ListOf{element_spec: el}) do
    %{"type" => "array", "items" => to_json_schema(el)}
  end

  defp to_json_schema(%Cond{}) do
    %{"description" => "conditional spec — branches depend on runtime values, no static JSON Schema equivalent"}
  end

  # ---------------------------------------------------------------------------
  # Transparent wrappers
  # ---------------------------------------------------------------------------

  # Default — emit the inner schema with a "default" keyword
  defp to_json_schema(%Default{spec: inner, value: value}) do
    to_json_schema(inner)
    |> Map.put("default", encode_default(value))
  end

  # Transform, Validate — emit the inner schema; the function is invisible
  defp to_json_schema(%Transform{spec: inner}), do: to_json_schema(inner)
  defp to_json_schema(%Validate{spec: inner}),  do: to_json_schema(inner)

  # Ref — resolve and inline
  defp to_json_schema(%Ref{name: name}) do
    to_json_schema(Gladius.Registry.fetch!(name))
  rescue
    _ -> %{"description" => "unresolvable ref :#{name}"}
  end

  # ---------------------------------------------------------------------------
  # Schema
  # ---------------------------------------------------------------------------

  defp to_json_schema(%Schema{keys: keys, open?: open?}) do
    {required_names, properties} =
      Enum.reduce(keys, {[], %{}}, fn %SchemaKey{name: name, spec: spec, required: req}, {reqs, props} ->
        key    = Atom.to_string(name)
        schema = to_json_schema(spec)
        reqs   = if req, do: [key | reqs], else: reqs
        {reqs, Map.put(props, key, schema)}
      end)

    result = %{
      "type"                 => "object",
      "properties"           => properties,
      "additionalProperties" => open?
    }

    case Enum.reverse(required_names) do
      []    -> result
      names -> Map.put(result, "required", names)
    end
  end

  # ---------------------------------------------------------------------------
  # Constraint helpers
  # ---------------------------------------------------------------------------

  defp apply_string_constraints(schema, cs) do
    schema
    |> then(fn s ->
      cond do
        exact = Keyword.get(cs, :size?) ->
          s |> Map.put("minLength", exact) |> Map.put("maxLength", exact)
        true ->
          s
          |> maybe_put("minLength", string_min(cs))
          |> maybe_put("maxLength", Keyword.get(cs, :max_length))
      end
    end)
    |> then(fn s ->
      case Keyword.get(cs, :format) do
        nil   -> s
        regex ->
          pattern = regex |> Regex.source()
          Map.put(s, "pattern", pattern)
      end
    end)
  end

  defp string_min(cs) do
    cond do
      Keyword.get(cs, :filled?, false) -> max(1, Keyword.get(cs, :min_length, 1))
      n = Keyword.get(cs, :min_length) -> n
      true -> nil
    end
  end

  defp apply_numeric_constraints(schema, cs) do
    schema
    |> maybe_put("minimum",          Keyword.get(cs, :gte?))
    |> maybe_put("exclusiveMinimum", Keyword.get(cs, :gt?))
    |> maybe_put("maximum",          Keyword.get(cs, :lte?))
    |> maybe_put("exclusiveMaximum", Keyword.get(cs, :lt?))
  end

  # ---------------------------------------------------------------------------
  # Utilities
  # ---------------------------------------------------------------------------

  defp maybe_put(map, _key, nil),   do: map
  defp maybe_put(map, key, value),  do: Map.put(map, key, value)

  # Encode default values for JSON Schema output.
  # Atoms become strings (except nil/true/false which are JSON native).
  defp encode_default(nil),   do: nil
  defp encode_default(true),  do: true
  defp encode_default(false), do: false
  defp encode_default(v) when is_atom(v), do: Atom.to_string(v)
  defp encode_default(v), do: v
end
