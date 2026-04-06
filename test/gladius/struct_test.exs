defmodule Gladius.StructTest do
  use ExUnit.Case, async: true

  import Gladius

  # ---------------------------------------------------------------------------
  # Test fixtures
  # ---------------------------------------------------------------------------

  # User has extra fields beyond most test schemas — tests use open_schema
  # when the intent is to test struct-input behaviour, not closed-schema rules.
  defmodule User do
    defstruct [:name, :email, :age, :role]
  end

  defmodule Address do
    defstruct [:street, :city, :zip]
  end

  defmodule RawUser do
    defstruct [:age]
  end

  defmodule CoercedUser do
    defstruct [:name, :age]
  end

  defmodule UserWithAddress do
    defstruct [:name, :address]
  end

  defmodule Schemas do
    import Gladius

    defschema :point, struct: true do
      schema(%{
        required(:x) => integer(),
        required(:y) => integer()
      })
    end

    defschema :person, struct: true do
      schema(%{
        required(:name)  => transform(string(:filled?), &String.trim/1),
        optional(:score) => default(integer(gte?: 0), 0)
      })
    end
  end

  # ---------------------------------------------------------------------------
  # Part A — conform/2 accepts structs as input
  # ---------------------------------------------------------------------------

  describe "conform/2 with struct input" do
    test "validates a struct against a schema — happy path" do
      # open_schema: User has :age/:role fields not in schema; nil values
      # from Map.from_struct would be rejected by a closed schema as unknown keys.
      s = open_schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(:filled?, format: ~r/@/)
      })

      user = %User{name: "Mark", email: "mark@x.com"}
      assert {:ok, result} = conform(s, user)
      assert result.name  == "Mark"
      assert result.email == "mark@x.com"
    end

    test "output is a plain map, not the original struct type" do
      s = open_schema(%{required(:name) => string(:filled?)})
      user = %User{name: "Mark"}
      {:ok, result} = conform(s, user)
      refute is_struct(result)
      assert is_map(result)
    end

    test "returns errors for invalid struct fields" do
      # CoercedUser only has :name and :age — matches the schema exactly
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 18)
      })

      user = %CoercedUser{name: "", age: 15}
      assert {:error, errors} = conform(s, user)
      assert Enum.any?(errors, &(&1.path == [:name]))
      assert Enum.any?(errors, &(&1.path == [:age]))
    end

    test "nil struct fields in a closed schema are treated as unknown keys" do
      # Documents the actual behaviour: Map.from_struct includes nil fields,
      # and a closed schema rejects them as unknown keys.
      s = schema(%{required(:name) => string(:filled?)})
      user = %User{name: "Mark"}  # email/age/role are nil but present in map
      assert {:error, errors} = conform(s, user)
      assert Enum.any?(errors, &(&1.predicate == :unknown_key?))
    end

    test "open_schema accepts nil struct fields without error" do
      s = open_schema(%{
        required(:name)  => string(:filled?),
        optional(:role)  => atom()
      })

      user = %User{name: "Mark", role: nil}
      {:ok, result} = conform(s, user)
      assert result.name == "Mark"
    end

    test "coercion works on struct fields" do
      s = schema(%{required(:age) => coerce(integer(), from: :string)})
      user = %RawUser{age: "33"}
      assert {:ok, %{age: 33}} = conform(s, user)
    end

    test "transform works on struct fields" do
      # CoercedUser has exactly :name and :age — use open_schema to avoid
      # the :age nil being an unknown key when only testing :name
      s = open_schema(%{required(:name) => transform(string(:filled?), &String.trim/1)})
      user = %User{name: "  Mark  "}
      assert {:ok, result} = conform(s, user)
      assert result.name == "Mark"
    end

    test "nested struct is converted recursively when schema is nested" do
      # Use open_schema for address so Address's :zip nil field passes through
      address_schema = open_schema(%{
        required(:street) => string(:filled?),
        required(:city)   => string(:filled?)
      })

      s = open_schema(%{
        required(:name)    => string(:filled?),
        required(:address) => address_schema
      })

      input = %UserWithAddress{
        name:    "Mark",
        address: %Address{street: "123 Main", city: "Culpeper", zip: nil}
      }

      assert {:ok, result} = conform(s, input)
      assert result.name             == "Mark"
      assert result.address.street   == "123 Main"
      assert result.address.city     == "Culpeper"
    end

    test "closed schema rejects struct fields not declared in schema" do
      s = schema(%{required(:name) => string(:filled?)})
      user = %CoercedUser{name: "Mark", age: 33}
      assert {:error, errors} = conform(s, user)
      assert Enum.any?(errors, &(&1.predicate == :unknown_key?))
    end

    test "valid?/2 works with struct input" do
      s = open_schema(%{required(:name) => string(:filled?)})
      assert valid?(s, %User{name: "Mark"})
      refute valid?(s, %User{name: ""})
    end

    test "explain/2 works with struct input" do
      s = open_schema(%{required(:name) => string(:filled?)})
      result = explain(s, %User{name: ""})
      refute result.valid?
      assert result.formatted =~ "filled"
    end
  end

  # ---------------------------------------------------------------------------
  # Part B — conform_struct/2
  # ---------------------------------------------------------------------------

  describe "conform_struct/2" do
    test "validates and re-wraps in the original struct type" do
      s = open_schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(:filled?, format: ~r/@/)
      })

      user = %User{name: "Mark", email: "mark@x.com"}
      assert {:ok, %User{name: "Mark", email: "mark@x.com"}} =
               Gladius.conform_struct(s, user)
    end

    test "shaped values (coercions, transforms) are reflected in the returned struct" do
      s = schema(%{
        required(:name) => transform(string(:filled?), &String.trim/1),
        required(:age)  => coerce(integer(), from: :string)
      })

      user = %CoercedUser{name: "  Mark  ", age: "33"}
      assert {:ok, %CoercedUser{name: "Mark", age: 33}} =
               Gladius.conform_struct(s, user)
    end

    test "returns error tuple on validation failure — same format as conform/2" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 18)
      })

      user = %CoercedUser{name: "", age: 10}
      assert {:error, errors} = Gladius.conform_struct(s, user)
      assert is_list(errors)
      assert Enum.all?(errors, &match?(%Gladius.Error{}, &1))
    end

    test "requires a struct as input — plain maps are rejected" do
      s = schema(%{required(:name) => string(:filled?)})
      assert {:error, [error]} = Gladius.conform_struct(s, %{name: "Mark"})
      assert error.message =~ "struct"
    end

    test "requires a struct as input — other values are rejected" do
      s = schema(%{required(:name) => string(:filled?)})
      assert {:error, [error]} = Gladius.conform_struct(s, "not a struct")
      assert error.message =~ "struct"
    end

    test "open_schema preserves extra keys in the struct" do
      s = open_schema(%{required(:name) => string(:filled?)})
      user = %User{name: "Mark", email: "mark@x.com", age: 33}
      {:ok, result} = Gladius.conform_struct(s, user)
      assert result.name  == "Mark"
      assert result.email == "mark@x.com"
      assert result.age   == 33
    end

    test "closed schema rejects struct fields not in schema" do
      s = schema(%{required(:name) => string(:filled?)})
      user = %CoercedUser{name: "Mark", age: 33}
      assert {:error, _} = Gladius.conform_struct(s, user)
    end
  end

  # ---------------------------------------------------------------------------
  # Part B — defschema struct: true
  # ---------------------------------------------------------------------------

  describe "defschema struct: true" do
    test "generates a struct module matching the schema fields" do
      assert function_exported?(Gladius.StructTest.Schemas, :point, 1)
      assert function_exported?(Gladius.StructTest.Schemas, :point!, 1)
    end

    test "conform returns a struct of the generated type" do
      assert {:ok, result} = Schemas.point(%{x: 3, y: 4})
      assert is_struct(result)
      assert result.__struct__ == Gladius.StructTest.Schemas.PointSchema
      assert result.x == 3
      assert result.y == 4
    end

    test "bang variant returns the struct directly" do
      result = Schemas.point!(%{x: 1, y: 2})
      assert %Gladius.StructTest.Schemas.PointSchema{x: 1, y: 2} = result
    end

    test "validation errors are still returned on invalid input" do
      assert {:error, [error]} = Schemas.point(%{x: "not_int", y: 0})
      assert error.path == [:x]
    end

    test "transforms run before struct wrapping" do
      assert {:ok, result} = Schemas.person(%{name: "  Mark  "})
      assert result.name == "Mark"
    end

    test "defaults are injected before struct wrapping" do
      assert {:ok, result} = Schemas.person(%{name: "Mark"})
      assert result.score == 0
    end

    test "bang raises ConformError on failure" do
      assert_raise Gladius.ConformError, fn ->
        Schemas.point!(%{x: "bad", y: 0})
      end
    end
  end
end
