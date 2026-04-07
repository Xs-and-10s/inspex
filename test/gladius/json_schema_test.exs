defmodule Gladius.JsonSchemaTest do
  use ExUnit.Case, async: true

  import Gladius

  # ---------------------------------------------------------------------------
  # Primitives
  # ---------------------------------------------------------------------------

  describe "string specs" do
    test "bare string" do
      assert Gladius.Schema.to_json_schema(string()) ==
               %{"$schema" => "https://json-schema.org/draft/2020-12/schema",
                 "type" => "string"}
    end

    test "filled?" do
      js = Gladius.Schema.to_json_schema(string(:filled?))
      assert js["type"] == "string"
      assert js["minLength"] == 1
    end

    test "min_length" do
      js = Gladius.Schema.to_json_schema(string(min_length: 3))
      assert js["minLength"] == 3
    end

    test "max_length" do
      js = Gladius.Schema.to_json_schema(string(max_length: 50))
      assert js["maxLength"] == 50
    end

    test "size? maps to both minLength and maxLength" do
      js = Gladius.Schema.to_json_schema(string(size?: 5))
      assert js["minLength"] == 5
      assert js["maxLength"] == 5
    end

    test "format regex becomes pattern" do
      js = Gladius.Schema.to_json_schema(string(format: ~r/^\d{4}$/))
      assert js["pattern"] == "^\\d{4}$"
    end

    test "filled? + min_length uses the larger value" do
      js = Gladius.Schema.to_json_schema(string(:filled?, min_length: 3))
      assert js["minLength"] == 3
    end

    test "filled? + format" do
      js = Gladius.Schema.to_json_schema(string(:filled?, format: ~r/@/))
      assert js["minLength"] == 1
      assert js["pattern"] == "@"
    end
  end

  describe "integer specs" do
    test "bare integer" do
      js = Gladius.Schema.to_json_schema(integer())
      assert js["type"] == "integer"
    end

    test "gte? becomes minimum" do
      js = Gladius.Schema.to_json_schema(integer(gte?: 0))
      assert js["minimum"] == 0
    end

    test "gt? becomes exclusiveMinimum" do
      js = Gladius.Schema.to_json_schema(integer(gt?: 0))
      assert js["exclusiveMinimum"] == 0
    end

    test "lte? becomes maximum" do
      js = Gladius.Schema.to_json_schema(integer(lte?: 100))
      assert js["maximum"] == 100
    end

    test "lt? becomes exclusiveMaximum" do
      js = Gladius.Schema.to_json_schema(integer(lt?: 100))
      assert js["exclusiveMaximum"] == 100
    end

    test "in? becomes enum" do
      js = Gladius.Schema.to_json_schema(integer(in?: [1, 2, 3]))
      assert js["enum"] == [1, 2, 3]
      refute Map.has_key?(js, "type")
    end

    test "range constraints combined" do
      js = Gladius.Schema.to_json_schema(integer(gte?: 1, lte?: 100))
      assert js["minimum"] == 1
      assert js["maximum"] == 100
    end
  end

  describe "other primitives" do
    test "float" do
      assert Gladius.Schema.to_json_schema(float())["type"] == "number"
    end

    test "number" do
      assert Gladius.Schema.to_json_schema(number())["type"] == "number"
    end

    test "boolean" do
      assert Gladius.Schema.to_json_schema(boolean())["type"] == "boolean"
    end

    test "nil_spec" do
      assert Gladius.Schema.to_json_schema(nil_spec())["type"] == "null"
    end

    test "any produces empty schema" do
      js = Gladius.Schema.to_json_schema(any())
      # only $schema header, no type constraint
      refute Map.has_key?(js, "type")
    end

    test "map" do
      assert Gladius.Schema.to_json_schema(map())["type"] == "object"
    end

    test "list" do
      assert Gladius.Schema.to_json_schema(list())["type"] == "array"
    end
  end

  describe "atom specs" do
    test "bare atom becomes string" do
      assert Gladius.Schema.to_json_schema(atom())["type"] == "string"
    end

    test "atom(in?: [...]) becomes enum of strings" do
      js = Gladius.Schema.to_json_schema(atom(in?: [:admin, :user]))
      assert js["enum"] == ["admin", "user"]
      refute Map.has_key?(js, "type")
    end
  end

  # ---------------------------------------------------------------------------
  # Combinators
  # ---------------------------------------------------------------------------

  describe "combinators" do
    test "list_of" do
      js = Gladius.Schema.to_json_schema(list_of(integer(gte?: 0)))
      assert js["type"] == "array"
      assert js["items"]["type"] == "integer"
      assert js["items"]["minimum"] == 0
    end

    test "maybe produces oneOf with null" do
      js = Gladius.Schema.to_json_schema(maybe(string(:filled?)))
      assert js["oneOf"] == [
        %{"type" => "null"},
        %{"type" => "string", "minLength" => 1}
      ]
    end

    test "all_of" do
      js = Gladius.Schema.to_json_schema(all_of([integer(), integer(gte?: 0)]))
      assert js["allOf"] == [
        %{"type" => "integer"},
        %{"type" => "integer", "minimum" => 0}
      ]
    end

    test "any_of" do
      js = Gladius.Schema.to_json_schema(any_of([integer(), string()]))
      assert js["anyOf"] == [
        %{"type" => "integer"},
        %{"type" => "string"}
      ]
    end

    test "not_spec" do
      js = Gladius.Schema.to_json_schema(not_spec(string()))
      assert js["not"] == %{"type" => "string"}
    end

    test "cond_spec produces description" do
      js = Gladius.Schema.to_json_schema(cond_spec(&is_binary/1, string()))
      assert is_binary(js["description"])
      assert js["description"] =~ "conditional"
    end
  end

  # ---------------------------------------------------------------------------
  # Transparent wrappers
  # ---------------------------------------------------------------------------

  describe "transparent wrappers" do
    test "transform passes through to inner spec" do
      js = Gladius.Schema.to_json_schema(transform(string(:filled?), &String.trim/1))
      assert js["type"] == "string"
      assert js["minLength"] == 1
    end

    test "coerce passes through to inner spec" do
      js = Gladius.Schema.to_json_schema(coerce(integer(gte?: 0), from: :string))
      assert js["type"] == "integer"
      assert js["minimum"] == 0
    end

    test "validate passes through to inner spec" do
      s =
        schema(%{required(:x) => integer(), required(:y) => integer()})
        |> validate(fn _ -> :ok end)

      js = Gladius.Schema.to_json_schema(s)
      assert js["type"] == "object"
      assert Map.has_key?(js["properties"], "x")
    end

    test "default adds default keyword" do
      js = Gladius.Schema.to_json_schema(default(integer(gte?: 0), 42))
      assert js["type"] == "integer"
      assert js["default"] == 42
    end

    test "default with atom value encodes as string" do
      js = Gladius.Schema.to_json_schema(default(atom(in?: [:admin, :user]), :user))
      assert js["default"] == "user"
    end

    test "default with nil value encodes as null" do
      js = Gladius.Schema.to_json_schema(default(maybe(string()), nil))
      assert Map.has_key?(js, "default")
      assert js["default"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Predicate spec
  # ---------------------------------------------------------------------------

  describe "predicate spec" do
    test "spec(pred) produces description" do
      js = Gladius.Schema.to_json_schema(spec(&is_integer/1))
      assert is_binary(js["description"])
      assert js["description"] =~ "custom predicate"
    end
  end

  # ---------------------------------------------------------------------------
  # ref/1
  # ---------------------------------------------------------------------------

  describe "ref/1" do
    test "ref is resolved and inlined" do
      Gladius.Registry.register(:json_schema_test_email, string(:filled?, format: ~r/@/))
      js = Gladius.Schema.to_json_schema(ref(:json_schema_test_email))
      assert js["type"] == "string"
      assert js["minLength"] == 1
      assert js["pattern"] == "@"
    end

    test "unresolvable ref produces description" do
      js = Gladius.Schema.to_json_schema(ref(:nonexistent_ref_xyz))
      assert is_binary(js["description"])
      assert js["description"] =~ "unresolvable"
    end
  end

  # ---------------------------------------------------------------------------
  # Schema
  # ---------------------------------------------------------------------------

  describe "schema/1" do
    test "produces object type with properties and required" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 0),
        optional(:role) => atom(in?: [:admin, :user])
      })

      js = Gladius.Schema.to_json_schema(s)
      assert js["type"] == "object"
      assert is_map(js["properties"])
      assert Map.has_key?(js["properties"], "name")
      assert Map.has_key?(js["properties"], "age")
      assert Map.has_key?(js["properties"], "role")
    end

    test "required list contains only required fields" do
      s = schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(:filled?),
        optional(:role)  => atom()
      })

      js = Gladius.Schema.to_json_schema(s)
      assert "name" in js["required"]
      assert "email" in js["required"]
      refute "role" in js["required"]
    end

    test "closed schema has additionalProperties: false" do
      s = schema(%{required(:x) => integer()})
      assert Gladius.Schema.to_json_schema(s)["additionalProperties"] == false
    end

    test "open schema has additionalProperties: true" do
      s = open_schema(%{required(:x) => integer()})
      assert Gladius.Schema.to_json_schema(s)["additionalProperties"] == true
    end

    test "no required key when all fields are optional" do
      s = schema(%{optional(:x) => integer(), optional(:y) => string()})
      js = Gladius.Schema.to_json_schema(s)
      refute Map.has_key?(js, "required")
    end

    test "nested schema is inlined" do
      address = schema(%{
        required(:street) => string(:filled?),
        required(:zip)    => string(size?: 5)
      })

      s = schema(%{
        required(:name)    => string(:filled?),
        required(:address) => address
      })

      js = Gladius.Schema.to_json_schema(s)
      addr_js = js["properties"]["address"]
      assert addr_js["type"] == "object"
      assert Map.has_key?(addr_js["properties"], "street")
      assert Map.has_key?(addr_js["properties"], "zip")
      assert addr_js["properties"]["zip"]["minLength"] == 5
      assert addr_js["properties"]["zip"]["maxLength"] == 5
    end

    test "list_of(schema) nested" do
      tag_schema = schema(%{
        required(:name)  => string(:filled?),
        optional(:color) => string()
      })

      s = schema(%{
        required(:name) => string(:filled?),
        required(:tags) => list_of(tag_schema)
      })

      js = Gladius.Schema.to_json_schema(s)
      tags_js = js["properties"]["tags"]
      assert tags_js["type"] == "array"
      assert tags_js["items"]["type"] == "object"
      assert Map.has_key?(tags_js["items"]["properties"], "name")
    end
  end

  # ---------------------------------------------------------------------------
  # Options
  # ---------------------------------------------------------------------------

  describe "options" do
    test "title option adds title to root" do
      s = schema(%{required(:x) => integer()})
      js = Gladius.Schema.to_json_schema(s, title: "MySchema")
      assert js["title"] == "MySchema"
    end

    test "description option adds description to root" do
      s = schema(%{required(:x) => integer()})
      js = Gladius.Schema.to_json_schema(s, description: "A test schema")
      assert js["description"] == "A test schema"
    end

    test "schema_header: false omits $schema" do
      s = schema(%{required(:x) => integer()})
      js = Gladius.Schema.to_json_schema(s, schema_header: false)
      refute Map.has_key?(js, "$schema")
    end

    test "schema_header: true (default) includes $schema" do
      s = schema(%{required(:x) => integer()})
      js = Gladius.Schema.to_json_schema(s)
      assert js["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    end

    test "all options together" do
      s = schema(%{required(:x) => integer()})
      js = Gladius.Schema.to_json_schema(s,
        title: "Test",
        description: "A test",
        schema_header: true
      )
      assert js["title"] == "Test"
      assert js["description"] == "A test"
      assert Map.has_key?(js, "$schema")
    end
  end

  # ---------------------------------------------------------------------------
  # Extend / Selection integration
  # ---------------------------------------------------------------------------

  describe "extend/2 and selection/2" do
    test "extend result is introspectable" do
      base = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 0)
      })
      extended = extend(base, %{optional(:role) => atom(in?: [:admin, :user])})
      js = Gladius.Schema.to_json_schema(extended)
      assert Map.has_key?(js["properties"], "name")
      assert Map.has_key?(js["properties"], "age")
      assert Map.has_key?(js["properties"], "role")
      assert js["properties"]["role"]["enum"] == ["admin", "user"]
    end

    test "selection result produces subset schema" do
      s = schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(:filled?),
        required(:age)   => integer(gte?: 0)
      })
      patch = selection(s, [:name, :age])
      js = Gladius.Schema.to_json_schema(patch)
      assert Map.has_key?(js["properties"], "name")
      assert Map.has_key?(js["properties"], "age")
      refute Map.has_key?(js["properties"], "email")
      # selection makes all fields optional — required list should be empty or absent
      required = Map.get(js, "required", [])
      assert required == []
    end
  end

  # ---------------------------------------------------------------------------
  # Practical: Jason-encodable
  # ---------------------------------------------------------------------------

  describe "JSON encodability" do
    test "output contains only JSON-safe values" do
      s = schema(%{
        required(:name)    => string(:filled?),
        required(:age)     => integer(gte?: 0),
        optional(:role)    => default(atom(in?: [:admin, :user]), :user),
        optional(:address) => schema(%{
          required(:street) => string(:filled?),
          required(:zip)    => string(size?: 5)
        })
      })

      js = Gladius.Schema.to_json_schema(s)

      # Verify no atoms in values (would break Jason encoding)
      assert_json_safe(js)
    end

    defp assert_json_safe(value) do
      case value do
        v when is_binary(v) -> :ok
        v when is_number(v) -> :ok
        v when is_boolean(v) -> :ok
        nil -> :ok
        v when is_list(v) -> Enum.each(v, &assert_json_safe/1)
        v when is_map(v) ->
          Enum.each(v, fn {k, val} ->
            assert is_binary(k), "map key #{inspect(k)} is not a string"
            assert_json_safe(val)
          end)
        other ->
          flunk("non-JSON-safe value: #{inspect(other)}")
      end
    end
  end
end
