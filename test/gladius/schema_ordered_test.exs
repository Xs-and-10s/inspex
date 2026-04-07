defmodule Gladius.SchemaOrderedTest do
  use ExUnit.Case, async: true

  import Gladius

  # ---------------------------------------------------------------------------
  # Basic ordered construction
  # ---------------------------------------------------------------------------

  describe "schema/1 with list input" do
    test "returns a %Gladius.Schema{}" do
      s = schema([{required(:name), string(:filled?)}])
      assert %Gladius.Schema{} = s
    end

    test "field order is preserved" do
      s = schema([
        {required(:name),  string(:filled?)},
        {required(:email), string(:filled?, format: ~r/@/)},
        {required(:age),   integer(gte?: 0)},
        {optional(:role),  atom(in?: [:admin, :user])}
      ])

      names = Enum.map(s.keys, & &1.name)
      assert names == [:name, :email, :age, :role]
    end

    test "required and optional flags are preserved" do
      s = schema([
        {required(:name), string(:filled?)},
        {optional(:role), atom()}
      ])

      name_key = Enum.find(s.keys, &(&1.name == :name))
      role_key = Enum.find(s.keys, &(&1.name == :role))

      assert name_key.required == true
      assert role_key.required == false
    end

    test "bare atom keys treated as required" do
      s = schema([{:name, string(:filled?)}])
      assert hd(s.keys).required == true
      assert hd(s.keys).name == :name
    end

    test "open?: false by default" do
      s = schema([{required(:x), integer()}])
      refute s.open?
    end

    test "empty list produces empty schema" do
      s = schema([])
      assert s.keys == []
    end

    test "conform/2 works correctly with list-built schema" do
      s = schema([
        {required(:name),  string(:filled?)},
        {required(:email), string(:filled?, format: ~r/@/)}
      ])

      assert {:ok, %{name: "Mark", email: "mark@x.com"}} =
               conform(s, %{name: "Mark", email: "mark@x.com"})

      assert {:error, _} = conform(s, %{name: "", email: "mark@x.com"})
    end

    test "valid?/2 works with list-built schema" do
      s = schema([{required(:x), integer(gte?: 0)}])
      assert valid?(s, %{x: 5})
      refute valid?(s, %{x: -1})
    end
  end

  describe "open_schema/1 with list input" do
    test "open?: true" do
      s = open_schema([{required(:name), string(:filled?)}])
      assert s.open?
    end

    test "field order is preserved" do
      s = open_schema([
        {required(:c), integer()},
        {required(:a), integer()},
        {required(:b), integer()}
      ])

      names = Enum.map(s.keys, & &1.name)
      assert names == [:c, :a, :b]
    end

    test "extra keys pass through" do
      s = open_schema([{required(:name), string(:filled?)}])
      assert {:ok, result} = conform(s, %{name: "Mark", extra: "value"})
      assert result.extra == "value"
    end
  end

  # ---------------------------------------------------------------------------
  # Backward compatibility — map input still works
  # ---------------------------------------------------------------------------

  describe "backward compatibility — map input" do
    test "schema/1 still accepts a map" do
      s = schema(%{required(:name) => string(:filled?)})
      assert %Gladius.Schema{} = s
      assert length(s.keys) == 1
    end

    test "open_schema/1 still accepts a map" do
      s = open_schema(%{required(:name) => string(:filled?)})
      assert %Gladius.Schema{} = s
      assert s.open?
    end

    test "conform/2 still works with map-built schema" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 0)
      })
      assert {:ok, _} = conform(s, %{name: "Mark", age: 33})
    end
  end

  # ---------------------------------------------------------------------------
  # Order guarantee
  # ---------------------------------------------------------------------------

  describe "order guarantee" do
    test "first declared field is first in keys" do
      s = schema([
        {required(:z), string()},
        {required(:a), string()},
        {required(:m), string()}
      ])

      names = Enum.map(s.keys, & &1.name)
      assert names == [:z, :a, :m]
    end

    test "list-based schema reliably preserves order; map does not guarantee it" do
      # Documents the known limitation of map-based schemas.
      list_s = schema([
        {required(:z), string()},
        {required(:a), string()}
      ])

      list_names = Enum.map(list_s.keys, & &1.name)
      assert list_names == [:z, :a]
    end
  end

  # ---------------------------------------------------------------------------
  # Integration with extend/2 and selection/2
  # ---------------------------------------------------------------------------

  describe "integration with extend/2" do
    test "extending a list-built schema preserves base order" do
      base = schema([
        {required(:name),  string(:filled?)},
        {required(:email), string(:filled?)}
      ])

      extended = extend(base, %{optional(:role) => atom()})
      names = Enum.map(extended.keys, & &1.name)

      assert Enum.take(names, 2) == [:name, :email]
      assert List.last(names) == :role
    end

    test "selection/2 preserves relative declaration order" do
      s = schema([
        {required(:name),  string(:filled?)},
        {required(:email), string(:filled?)},
        {required(:age),   integer(gte?: 0)},
        {optional(:role),  atom()}
      ])

      patch = selection(s, [:age, :name])
      names = Enum.map(patch.keys, & &1.name)

      # name was declared before age, so name comes first
      assert names == [:name, :age]
    end
  end

  # ---------------------------------------------------------------------------
  # Integration with Gladius.Schema introspection
  # ---------------------------------------------------------------------------

  describe "introspection on list-built schemas" do
    test "field_names/1 returns fields in declaration order" do
      s = schema([
        {required(:z), string()},
        {required(:a), string()},
        {required(:m), string()}
      ])

      assert Gladius.Schema.field_names(s) == [:z, :a, :m]
    end

    test "required_fields/1 preserves declaration order" do
      s = schema([
        {required(:z), string()},
        {optional(:x), string()},
        {required(:a), string()}
      ])

      names = s |> Gladius.Schema.required_fields() |> Enum.map(& &1.name)
      assert names == [:z, :a]
    end
  end

  # ---------------------------------------------------------------------------
  # Integration with to_json_schema/1
  # ---------------------------------------------------------------------------

  describe "to_json_schema/1 with ordered schema" do
    test "required array reflects declaration order" do
      s = schema([
        {required(:name),  string(:filled?)},
        {required(:age),   integer(gte?: 0)},
        {optional(:role),  atom(in?: [:admin, :user])}
      ])

      js = Gladius.Schema.to_json_schema(s, schema_header: false)

      assert js["type"] == "object"
      assert js["required"] == ["name", "age"]
      assert Map.has_key?(js["properties"], "name")
      assert Map.has_key?(js["properties"], "age")
      assert Map.has_key?(js["properties"], "role")
    end

    test "required list order matches declaration order" do
      s = schema([
        {required(:c), string()},
        {optional(:x), string()},
        {required(:a), string()},
        {required(:b), string()}
      ])

      js = Gladius.Schema.to_json_schema(s, schema_header: false)
      assert js["required"] == ["c", "a", "b"]
    end

    test "nested list-built schemas are ordered correctly" do
      address = schema([
        {required(:street), string(:filled?)},
        {required(:zip),    string(size?: 5)},
        {optional(:city),   string()}
      ])

      s = schema([
        {required(:name),    string(:filled?)},
        {required(:address), address}
      ])

      js = Gladius.Schema.to_json_schema(s, schema_header: false)
      addr_js = js["properties"]["address"]
      assert addr_js["required"] == ["street", "zip"]
      assert Map.has_key?(addr_js["properties"], "street")
      assert Map.has_key?(addr_js["properties"], "zip")
      assert Map.has_key?(addr_js["properties"], "city")
    end
  end
end
