defmodule Gladius.Ecto do
  @moduledoc """
  Optional Ecto integration for Gladius.

  Converts a Gladius schema into an `Ecto.Changeset`, running full Gladius
  validation and mapping errors to changeset errors. Requires `ecto` to be
  present in your application's dependencies — Gladius does not pull it in
  by default.

  ## Usage

      # In your mix.exs — add alongside gladius:
      {:ecto, "~> 3.0"}           # most Phoenix apps already have this

  ## Schemaless changeset (create workflows)

      params = %{"name" => "Mark", "email" => "MARK@X.COM", "age" => "33"}

      schema = schema(%{
        required(:name)  => string(:filled?),
        required(:email) => transform(string(:filled?, format: ~r/@/), &String.downcase/1),
        required(:age)   => coerce(integer(gte?: 18), from: :string),
        optional(:role)  => default(atom(in?: [:admin, :user]), :user)
      })

      Gladius.Ecto.changeset(schema, params)
      #=> %Ecto.Changeset{valid?: true,
      #=>   changes: %{name: "Mark", email: "mark@x.com", age: 33, role: :user}}

  ## Schema-aware changeset (update workflows)

  Pass an existing struct as the third argument. Ecto will only mark fields
  that differ from the struct's current values as changes.

      user = %User{name: "Mark", email: "mark@x.com", age: 33, role: :admin}
      Gladius.Ecto.changeset(schema, %{"name" => "Mark", "age" => "40"}, user)
      #=> %Ecto.Changeset{valid?: true, changes: %{age: 40}}

  ## Nested schemas

  When a field's spec is itself a `%Gladius.Schema{}` (or wraps one via
  `default/2`, `transform/2`, or `maybe/1`), `changeset/2` builds a nested
  `%Ecto.Changeset{}` for that field rather than casting it as a plain map.
  This is compatible with Phoenix `inputs_for` and `traverse_errors/2`.

      address_schema = schema(%{
        required(:street) => string(:filled?),
        required(:zip)    => string(size?: 5)
      })

      user_schema = schema(%{
        required(:name)    => string(:filled?),
        required(:address) => address_schema
      })

      cs = Gladius.Ecto.changeset(user_schema, %{
        name: "Mark",
        address: %{street: "1 Main St", zip: "bad"}
      })

      cs.valid?                 #=> false
      cs.changes.address        #=> %Ecto.Changeset{valid?: false, ...}

      Ecto.Changeset.traverse_errors(cs, & &1)
      #=> %{address: %{zip: [{"must be exactly 5 characters", []}]}}

  ## Errors

  On validation failure, top-level Gladius errors are mapped to changeset
  errors keyed on the field name. Nested errors appear in nested changesets.

  ## Composing with Ecto validators

  The returned changeset is a plain `%Ecto.Changeset{}` — pipe Ecto validators
  after as normal.

      params
      |> Gladius.Ecto.changeset(schema)
      |> Ecto.Changeset.unique_constraint(:email)
      |> Repo.insert()

  ## Availability guard

  This module only exists when `Ecto.Changeset` is compiled into the project.
  """

  if Code.ensure_loaded?(Ecto.Changeset) do
    alias Gladius.{Schema, SchemaKey, Spec, Default, Transform, Maybe, All, Any, Ref, Validate, ListOf, Error}

    @doc """
    Builds an `Ecto.Changeset` from a Gladius schema and params map.

    Runs full Gladius validation including coercions, transforms, and defaults.
    On success the changeset is valid and its `changes` contain the shaped
    output. On failure the changeset is invalid and its `errors` contain one
    entry per top-level `%Gladius.Error{}`; nested schema fields carry their
    own invalid nested changeset.

    ## Arguments

    - `gladius_schema` — a `%Gladius.Schema{}` built with `schema/1` or
      `open_schema/1`.
    - `params` — the raw input map (string or atom keys).
    - `base` — the base data for the changeset. Defaults to `%{}` for
      schemaless changesets (create workflows). Pass an existing struct for
      update workflows.
    """
    @spec changeset(Schema.t(), map(), map() | struct()) :: Ecto.Changeset.t()
    def changeset(gladius_schema, params, base \\ %{})

    def changeset(%Schema{} = gladius_schema, params, base) when is_map(params) do
      types  = infer_types(gladius_schema)
      fields = Map.keys(types)
      data   = {base, types}

      # Normalise string keys → atoms before conforming.
      # Phoenix sends all form/JSON params as string-keyed maps.
      atom_params = atomize_keys(params)

      # Fields whose spec is (or wraps) a nested %Schema{} — their errors are
      # handled by recursive nested changesets rather than the parent's errors list.
      nested_field_names =
        gladius_schema.keys
        |> Enum.filter(fn %SchemaKey{spec: spec} ->
          unwrap_to_schema(spec) != nil or unwrap_list_schema(spec) != nil
        end)
        |> MapSet.new(& &1.name)

      cs =
        case Gladius.conform(gladius_schema, atom_params) do
          {:ok, shaped} ->
            # Pass already-shaped output — types are correct, no double-coercion.
            Ecto.Changeset.cast(data, shaped, fields)

          {:error, errors} ->
            # Exclude errors whose first path segment is a nested-schema field —
            # those are handled by the recursive nested changeset in apply_nested.
            # All other errors (root, single-field, and list-element errors) belong
            # on the parent changeset.
            top_errors =
              Enum.filter(errors, fn
                %Error{path: []}        -> true
                %Error{path: [first | _]} -> not MapSet.member?(nested_field_names, first)
              end)

            data
            |> Ecto.Changeset.cast(atom_params, fields)
            |> Map.put(:valid?, false)
            |> apply_errors(top_errors)
        end

      # Replace plain maps with nested changesets for any field whose spec
      # is (or wraps) a %Schema{} or list_of(schema).
      cs
      |> apply_nested(gladius_schema.keys, atom_params)
      |> apply_embed_types(gladius_schema.keys)
    end

    # -------------------------------------------------------------------------
    # Nested changeset application
    # -------------------------------------------------------------------------

    # Iterate schema keys; for each field whose spec resolves to a nested schema
    # or list_of(schema), build nested changeset(s) and put into parent changes.
    defp apply_nested(cs, keys, atom_params) do
      Enum.reduce(keys, cs, fn %SchemaKey{name: name, spec: spec, required: required}, acc ->
        raw = Map.get(atom_params, name)

        cond do
          # ── Single nested schema ───────────────────────────────────────────
          match?(%Schema{}, unwrap_to_schema(spec)) and is_map(raw) and not is_struct(raw) ->
            nested_schema = unwrap_to_schema(spec)
            nested_cs     = changeset(nested_schema, raw)
            acc
            |> Ecto.Changeset.put_change(name, nested_cs)
            |> invalidate_if(not nested_cs.valid?)

          # ── list_of(schema) — many embed ───────────────────────────────────
          unwrap_list_schema(spec) != nil and is_list(raw) ->
            element_schema = unwrap_list_schema(spec)
            nested_list    = Enum.map(raw, &changeset(element_schema, &1))
            all_valid?     = Enum.all?(nested_list, & &1.valid?)
            acc
            |> Ecto.Changeset.put_change(name, nested_list)
            |> invalidate_if(not all_valid?)

          # ── list_of(schema) with empty list ────────────────────────────────
          unwrap_list_schema(spec) != nil and raw == [] ->
            Ecto.Changeset.put_change(acc, name, [])

          # ── Required nested field absent — error already in top_errors ─────
          required and is_nil(raw) ->
            acc

          # ── Optional nested field absent — nothing to do ───────────────────
          true ->
            acc
        end
      end)
    end

    # Marks the changeset invalid when the condition is true.
    defp invalidate_if(cs, false), do: cs
    defp invalidate_if(cs, true),  do: Map.put(cs, :valid?, false)

    # After nested changesets are placed in changes, overwrite the types map
    # so Phoenix's inputs_for/4 and Ecto.Changeset.traverse_errors/2 recognise
    # them as embeds. This MUST run after cast/4 — cast doesn't handle embed types.
    defp apply_embed_types(cs, keys) do
      Enum.reduce(keys, cs, fn %SchemaKey{name: name, spec: spec}, acc ->
        case embed_cardinality(spec) do
          nil  -> acc
          card -> %{acc | types: Map.put(acc.types, name, embed_type(card, name))}
        end
      end)
    end

    # -------------------------------------------------------------------------
    # Schema unwrapping
    # -------------------------------------------------------------------------

    # Returns the nested %Schema{} if the spec is (or wraps) one; nil otherwise.
    defp unwrap_to_schema(%Schema{} = s),           do: s
    defp unwrap_to_schema(%Default{spec: inner}),   do: unwrap_to_schema(inner)
    defp unwrap_to_schema(%Transform{spec: inner}), do: unwrap_to_schema(inner)
    defp unwrap_to_schema(%Maybe{spec: inner}),     do: unwrap_to_schema(inner)
    defp unwrap_to_schema(%Validate{spec: inner}),  do: unwrap_to_schema(inner)

    defp unwrap_to_schema(%Ref{name: n}) do
      unwrap_to_schema(Gladius.Registry.fetch!(n))
    rescue
      _ -> nil
    end

    defp unwrap_to_schema(_), do: nil

    # Returns the element %Schema{} if the spec is list_of(schema); nil otherwise.
    defp unwrap_list_schema(%ListOf{element_spec: el}),  do: unwrap_to_schema(el)
    defp unwrap_list_schema(%Default{spec: inner}),      do: unwrap_list_schema(inner)
    defp unwrap_list_schema(%Transform{spec: inner}),    do: unwrap_list_schema(inner)
    defp unwrap_list_schema(%Maybe{spec: inner}),        do: unwrap_list_schema(inner)
    defp unwrap_list_schema(%Validate{spec: inner}),     do: unwrap_list_schema(inner)

    defp unwrap_list_schema(%Ref{name: n}) do
      unwrap_list_schema(Gladius.Registry.fetch!(n))
    rescue
      _ -> nil
    end

    defp unwrap_list_schema(_), do: nil

    # -------------------------------------------------------------------------
    # Type inference
    # -------------------------------------------------------------------------

    defp infer_types(%Schema{keys: keys}) do
      Map.new(keys, fn %SchemaKey{name: name, spec: spec} ->
        {name, infer_ecto_type(spec, name)}
      end)
    end

    # infer_ecto_type/2 — always returns a primitive Ecto type safe for cast/4.
    # Embed types ({:parameterized, Ecto.Embedded, ...}) are injected AFTER
    # casting via apply_embed_types/2, not during cast — Ecto.Type.cast_fun/1
    # does not handle embed types and raises FunctionClauseError if passed one.
    defp infer_ecto_type(spec, _field_name), do: infer_scalar_type(spec)

    # Determine if a spec resolves to a nested schema (returning embed cardinality)
    defp embed_cardinality(%Schema{}),             do: :one
    defp embed_cardinality(%Default{spec: s}),     do: embed_cardinality(s)
    defp embed_cardinality(%Transform{spec: s}),   do: embed_cardinality(s)
    defp embed_cardinality(%Maybe{spec: s}),       do: embed_cardinality(s)
    defp embed_cardinality(%Validate{spec: s}),    do: embed_cardinality(s)
    defp embed_cardinality(%ListOf{element_spec: el}) do
      if embed_cardinality(el) != nil, do: :many, else: nil
    end
    defp embed_cardinality(%Ref{name: n}) do
      embed_cardinality(Gladius.Registry.fetch!(n))
    rescue
      _ -> nil
    end
    defp embed_cardinality(_), do: nil

    # Build a parameterized Ecto.Embedded type for inputs_for compatibility
    defp embed_type(cardinality, field) do
      {:parameterized, Ecto.Embedded, %Ecto.Embedded{
        cardinality: cardinality,
        field:       field,
        owner:       nil,
        related:     nil,
        on_cast:     nil,
        on_replace:  :raise,
        unique:      true,
        ordered:     true
      }}
    end

    # Primitive / scalar type inference (non-embed fields)
    defp infer_scalar_type(%Spec{type: :string}),  do: :string
    defp infer_scalar_type(%Spec{type: :integer}), do: :integer
    defp infer_scalar_type(%Spec{type: :float}),   do: :float
    defp infer_scalar_type(%Spec{type: :number}),  do: :float
    defp infer_scalar_type(%Spec{type: :boolean}), do: :boolean
    defp infer_scalar_type(%Spec{type: :map}),     do: :map
    defp infer_scalar_type(%Spec{type: :atom}),    do: :any
    defp infer_scalar_type(%Spec{type: :any}),     do: :any
    defp infer_scalar_type(%Spec{type: :null}),    do: :any
    defp infer_scalar_type(%Spec{type: :list}),    do: {:array, :any}
    defp infer_scalar_type(%Spec{type: nil}),      do: :any

    defp infer_scalar_type(%Default{spec: inner}),   do: infer_scalar_type(inner)
    defp infer_scalar_type(%Transform{spec: inner}), do: infer_scalar_type(inner)
    defp infer_scalar_type(%Maybe{spec: inner}),     do: infer_scalar_type(inner)

    defp infer_scalar_type(%All{specs: [first | _]}), do: infer_scalar_type(first)
    defp infer_scalar_type(%All{specs: []}),           do: :any
    defp infer_scalar_type(%Any{}),                    do: :any

    defp infer_scalar_type(%Ref{name: n}) do
      infer_scalar_type(Gladius.Registry.fetch!(n))
    rescue
      _ -> :any
    end

    defp infer_scalar_type(%ListOf{element_spec: el}), do: {:array, infer_scalar_type(el)}
    defp infer_scalar_type(%Schema{}),                  do: :map
    defp infer_scalar_type(_),                          do: :any

    # -------------------------------------------------------------------------
    # Error mapping
    # -------------------------------------------------------------------------

    defp apply_errors(changeset, errors) do
      Enum.reduce(errors, changeset, fn %Error{path: path, message: message}, cs ->
        field = last_segment(path)
        Ecto.Changeset.add_error(cs, field, message)
      end)
    end

    # -------------------------------------------------------------------------
    # Key normalisation
    # -------------------------------------------------------------------------

    defp atomize_keys(params) when is_map(params) do
      Map.new(params, fn
        {k, v} when is_binary(k) ->
          atom =
            try do
              String.to_existing_atom(k)
            rescue
              ArgumentError -> k
            end
          {atom, atomize_keys(v)}
        {k, v} ->
          {k, atomize_keys(v)}
      end)
    end

    # Recurse into lists so nested params like [%{"name" => "x"}] get atomized
    defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)

    defp atomize_keys(other), do: other

    defp last_segment([]), do: :base

    defp last_segment(path) do
      case List.last(path) do
        segment when is_atom(segment)    -> segment
        segment when is_binary(segment)  ->
          try do
            String.to_existing_atom(segment)
          rescue
            ArgumentError -> :base
          end
        segment when is_integer(segment) -> :base
      end
    end

    # -------------------------------------------------------------------------
    # Public nested error traversal
    # -------------------------------------------------------------------------

    @doc """
    Recursively traverses a changeset built by `Gladius.Ecto.changeset/2-3`,
    collecting errors from nested changesets stored in `changes`.

    Ecto's built-in `traverse_errors/2` only recurses into `:embed`/`:assoc`
    typed fields. Because Gladius stores nested changesets under `:map` typed
    fields, use this function instead to get a nested error map.

    ## Example

        cs = Gladius.Ecto.changeset(user_schema, params)
        Gladius.Ecto.traverse_errors(cs, fn {msg, _opts} -> msg end)
        #=> %{address: %{zip: ["must be exactly 5 characters"]}}
    """
    @spec traverse_errors(Ecto.Changeset.t(), (tuple() -> term())) :: map()
    def traverse_errors(%Ecto.Changeset{errors: errors, changes: changes}, msg_func)
        when is_function(msg_func, 1) do
      top =
        errors
        |> Enum.reverse()
        |> Enum.reduce(%{}, fn {field, msg_opts}, acc ->
          Map.update(acc, field, [msg_func.(msg_opts)], &(&1 ++ [msg_func.(msg_opts)]))
        end)

      Enum.reduce(changes, top, fn {field, value}, acc ->
        case value do
          %Ecto.Changeset{} = nested ->
            nested_errors = traverse_errors(nested, msg_func)
            if nested_errors == %{}, do: acc, else: Map.put(acc, field, nested_errors)

          list when is_list(list) ->
            cs_list = Enum.filter(list, &is_struct(&1, Ecto.Changeset))
            if cs_list == [] do
              acc
            else
              errors_list = Enum.map(cs_list, &traverse_errors(&1, msg_func))
              if Enum.all?(errors_list, &(&1 == %{})) do
                acc
              else
                Map.put(acc, field, errors_list)
              end
            end

          _ ->
            acc
        end
      end)
    end
  end
end
