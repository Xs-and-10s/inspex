defmodule Gladius.SelectionTest do
  use ExUnit.Case, async: true

  import Gladius

  # Shared base schema used across most tests
  defp user_schema do
    schema(%{
      required(:name)  => string(:filled?),
      required(:email) => string(:filled?, format: ~r/@/),
      required(:age)   => integer(gte?: 0),
      optional(:role)  => atom(in?: [:admin, :user])
    })
  end

  # ---------------------------------------------------------------------------
  # selection/2 construction
  # ---------------------------------------------------------------------------

  describe "selection/2 construction" do
    test "returns a %Gladius.Schema{}" do
      s = selection(user_schema(), [:name, :email])
      assert %Gladius.Schema{} = s
    end

    test "selected keys are present in the result" do
      s = selection(user_schema(), [:name, :email])
      names = Enum.map(s.keys, & &1.name)
      assert :name  in names
      assert :email in names
    end

    test "non-selected keys are absent from the result" do
      s = selection(user_schema(), [:name, :email])
      names = Enum.map(s.keys, & &1.name)
      refute :age  in names
      refute :role in names
    end

    test "all selected keys are flattened to optional (required: false)" do
      # :name and :email were required in the source schema
      s = selection(user_schema(), [:name, :email])
      assert Enum.all?(s.keys, &(&1.required == false))
    end

    test "originally-optional keys remain optional after selection" do
      s = selection(user_schema(), [:role])
      [key] = s.keys
      assert key.required == false
    end

    test "original spec is preserved on each selected key" do
      s = selection(user_schema(), [:age])
      [key] = s.keys
      # The spec should still be integer(gte?: 0) — not stripped
      assert key.spec == integer(gte?: 0)
    end

    test "inherits open?: false from a closed source schema" do
      s = selection(user_schema(), [:name])
      refute s.open?
    end

    test "inherits open?: true from an open source schema" do
      base = open_schema(%{required(:name) => string(:filled?)})
      s    = selection(base, [:name])
      assert s.open?
    end

    test "empty field_names list returns a schema with no keys" do
      s = selection(user_schema(), [])
      assert s.keys == []
    end

    test "field names not in the source schema are silently ignored" do
      s = selection(user_schema(), [:name, :nonexistent])
      names = Enum.map(s.keys, & &1.name)
      assert names == [:name]
    end

    test "selecting all keys returns a fully-optional version of the schema" do
      s = selection(user_schema(), [:name, :email, :age, :role])
      assert length(s.keys) == 4
      assert Enum.all?(s.keys, &(&1.required == false))
    end
  end

  # ---------------------------------------------------------------------------
  # conform/2 with a selection — absent keys
  # ---------------------------------------------------------------------------

  describe "conform/2 — absent selected keys" do
    test "all keys absent returns {:ok, %{}}" do
      s = selection(user_schema(), [:name, :email])
      assert {:ok, %{}} = conform(s, %{})
    end

    test "some keys absent — only present keys appear in output" do
      s = selection(user_schema(), [:name, :email])
      assert {:ok, result} = conform(s, %{name: "Mark"})
      assert result == %{name: "Mark"}
      refute Map.has_key?(result, :email)
    end

    test "absent selected key with default spec — default is injected" do
      base = schema(%{
        required(:name) => string(:filled?),
        optional(:role) => default(atom(in?: [:admin, :user]), :user)
      })
      s = selection(base, [:name, :role])

      assert {:ok, result} = conform(s, %{name: "Mark"})
      assert result.role == :user
    end
  end

  # ---------------------------------------------------------------------------
  # conform/2 with a selection — present keys validated
  # ---------------------------------------------------------------------------

  describe "conform/2 — present keys still validated" do
    test "valid present key passes" do
      s = selection(user_schema(), [:name, :age])
      assert {:ok, %{name: "Mark", age: 33}} = conform(s, %{name: "Mark", age: 33})
    end

    test "invalid present key returns error" do
      s = selection(user_schema(), [:name, :age])
      assert {:error, [error]} = conform(s, %{name: "Mark", age: -1})
      assert error.path == [:age]
    end

    test "all selected keys invalid returns all errors" do
      s = selection(user_schema(), [:name, :age])
      assert {:error, errors} = conform(s, %{name: "", age: -1})
      assert length(errors) == 2
    end

    test "coercions run on selected keys" do
      base = schema(%{required(:age) => coerce(integer(gte?: 0), from: :string)})
      s    = selection(base, [:age])
      assert {:ok, %{age: 33}} = conform(s, %{age: "33"})
    end

    test "transforms run on selected keys" do
      base = schema(%{required(:name) => transform(string(:filled?), &String.trim/1)})
      s    = selection(base, [:name])
      assert {:ok, %{name: "Mark"}} = conform(s, %{name: "  Mark  "})
    end

    test "custom messages preserved on selected keys" do
      base = schema(%{required(:age) => integer(gte?: 18, message: "must be adult")})
      s    = selection(base, [:age])
      assert {:error, [error]} = conform(s, %{age: 15})
      assert error.message == "must be adult"
    end
  end

  # ---------------------------------------------------------------------------
  # conform/2 — closed schema rejects non-selected keys
  # ---------------------------------------------------------------------------

  describe "conform/2 — non-selected keys rejected in closed selection" do
    test "non-selected key in input returns unknown-key error" do
      s = selection(user_schema(), [:name])
      assert {:error, [error]} = conform(s, %{name: "Mark", age: 33})
      assert error.predicate == :unknown_key?
      assert error.path == [:age]
    end

    test "multiple non-selected keys all reported" do
      s = selection(user_schema(), [:name])
      assert {:error, errors} = conform(s, %{name: "Mark", age: 33, role: :admin})
      unknown = Enum.filter(errors, &(&1.predicate == :unknown_key?))
      assert length(unknown) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # conform/2 — open selection passes extra keys through
  # ---------------------------------------------------------------------------

  describe "conform/2 — open schema selection passes extra keys through" do
    test "non-selected keys pass through in an open selection" do
      base = open_schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 0)
      })
      s = selection(base, [:name])

      assert {:ok, result} = conform(s, %{name: "Mark", age: 33, extra: "ok"})
      assert result.name  == "Mark"
      assert result.age   == 33
      assert result.extra == "ok"
    end
  end

  # ---------------------------------------------------------------------------
  # PATCH workflow — the primary use case
  # ---------------------------------------------------------------------------

  describe "PATCH endpoint workflow" do
    test "partial update with one field" do
      patch = selection(user_schema(), [:name, :email, :age, :role])
      assert {:ok, %{name: "NewName"}} = conform(patch, %{name: "NewName"})
    end

    test "empty patch body is valid" do
      patch = selection(user_schema(), [:name, :email, :age, :role])
      assert {:ok, %{}} = conform(patch, %{})
    end

    test "all fields provided is valid" do
      patch = selection(user_schema(), [:name, :email, :age, :role])
      assert {:ok, result} = conform(patch, %{
        name:  "Mark",
        email: "mark@x.com",
        age:   33,
        role:  :admin
      })
      assert map_size(result) == 4
    end

    test "invalid field in patch returns error" do
      patch = selection(user_schema(), [:name, :email, :age, :role])
      assert {:error, [error]} = conform(patch, %{age: -1})
      assert error.path == [:age]
    end

    test "unknown field in patch returns error (prevents mass assignment)" do
      patch = selection(user_schema(), [:name])
      assert {:error, [error]} = conform(patch, %{name: "Mark", is_admin: true})
      assert error.predicate == :unknown_key?
    end
  end

  # ---------------------------------------------------------------------------
  # selection/2 on a defschema result
  # ---------------------------------------------------------------------------

  describe "selection/2 with defschema" do
    defmodule Schemas do
      import Gladius

      defschema :product do
        schema(%{
          required(:title) => string(:filled?),
          required(:price) => float(gt?: 0.0),
          required(:sku)   => string(size?: 8),
          optional(:stock) => integer(gte?: 0)
        })
      end
    end

    test "selection from a defschema-produced schema" do
      # Call the generated function to get the schema struct, then select
      patch = selection(
        schema(%{
          required(:title) => string(:filled?),
          required(:price) => float(gt?: 0.0),
          required(:sku)   => string(size?: 8),
          optional(:stock) => integer(gte?: 0)
        }),
        [:title, :price]
      )

      assert {:ok, %{title: "Widget"}} = conform(patch, %{title: "Widget"})
      assert {:ok, %{title: "Widget", price: 9.99}} =
               conform(patch, %{title: "Widget", price: 9.99})
    end
  end

  # ---------------------------------------------------------------------------
  # valid?/2 and explain/2 work with selections
  # ---------------------------------------------------------------------------

  describe "valid?/2 and explain/2" do
    test "valid?/2 returns true for valid partial input" do
      s = selection(user_schema(), [:name, :email])
      assert valid?(s, %{name: "Mark"})
      assert valid?(s, %{})
    end

    test "valid?/2 returns false for invalid partial input" do
      s = selection(user_schema(), [:name])
      refute valid?(s, %{name: ""})
    end

    test "explain/2 formats errors correctly" do
      s      = selection(user_schema(), [:age])
      result = explain(s, %{age: -1})
      refute result.valid?
      assert result.formatted =~ "age"
    end
  end
end
