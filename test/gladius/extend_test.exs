defmodule Gladius.ExtendTest do
  use ExUnit.Case, async: true

  import Gladius

  # Shared base schema
  defp base do
    schema(%{
      required(:name)  => string(:filled?),
      required(:email) => string(:filled?, format: ~r/@/),
      required(:age)   => integer(gte?: 0),
      optional(:role)  => atom(in?: [:admin, :user])
    })
  end

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  describe "extend/2 construction" do
    test "returns a %Gladius.Schema{}" do
      assert %Gladius.Schema{} = extend(base(), %{})
    end

    test "extends with new required key" do
      s = extend(base(), %{required(:bio) => string()})
      names = Enum.map(s.keys, & &1.name)
      assert :bio in names
    end

    test "extends with new optional key" do
      s = extend(base(), %{optional(:bio) => string()})
      key = Enum.find(s.keys, &(&1.name == :bio))
      assert key
      refute key.required
    end

    test "base keys preserved in output" do
      s = extend(base(), %{required(:bio) => string()})
      names = Enum.map(s.keys, & &1.name)
      assert :name  in names
      assert :email in names
      assert :age   in names
      assert :role  in names
    end

    test "base key order is preserved — base keys first, new keys after" do
      s = extend(base(), %{required(:bio) => string(), required(:avatar) => string()})
      names = Enum.map(s.keys, & &1.name)
      base_names = [:name, :email, :age, :role]
      base_indices   = Enum.map(base_names, &Enum.find_index(names, fn n -> n == &1 end))
      new_indices    = Enum.map([:bio, :avatar], &Enum.find_index(names, fn n -> n == &1 end))
      assert Enum.max(base_indices) < Enum.min(new_indices)
    end

    test "inherits open?: false from closed base" do
      s = extend(base(), %{})
      refute s.open?
    end

    test "inherits open?: true from open base" do
      open_base = open_schema(%{required(:name) => string(:filled?)})
      s = extend(open_base, %{optional(:bio) => string()})
      assert s.open?
    end

    test "extend/3 with open?: true overrides closed base" do
      s = extend(base(), %{optional(:bio) => string()}, open?: true)
      assert s.open?
    end

    test "extend/3 with open?: false keeps closed on closed base" do
      s = extend(base(), %{optional(:bio) => string()}, open?: false)
      refute s.open?
    end

    test "empty extension map returns schema equivalent to base" do
      s = extend(base(), %{})
      assert length(s.keys) == length(base().keys)
    end
  end

  # ---------------------------------------------------------------------------
  # Key override
  # ---------------------------------------------------------------------------

  describe "extend/2 key override" do
    test "override changes the spec for an existing key" do
      s = extend(base(), %{required(:age) => integer(gte?: 21)})
      key = Enum.find(s.keys, &(&1.name == :age))
      assert key.spec == integer(gte?: 21)
    end

    test "override can change required → optional" do
      # :age was required in base
      s = extend(base(), %{optional(:age) => integer(gte?: 0)})
      key = Enum.find(s.keys, &(&1.name == :age))
      refute key.required
    end

    test "override can change optional → required" do
      # :role was optional in base
      s = extend(base(), %{required(:role) => atom(in?: [:admin])})
      key = Enum.find(s.keys, &(&1.name == :role))
      assert key.required
    end

    test "override preserves position of overridden key" do
      s = extend(base(), %{required(:email) => string(:filled?, format: ~r/\.com$/)})
      names = Enum.map(s.keys, & &1.name)
      base_names = Enum.map(base().keys, & &1.name)
      # email should be at the same index as in the base
      assert Enum.find_index(names, &(&1 == :email)) ==
             Enum.find_index(base_names, &(&1 == :email))
    end

    test "override does not duplicate the key" do
      s = extend(base(), %{required(:name) => string(:filled?, min_length: 2)})
      name_keys = Enum.filter(s.keys, &(&1.name == :name))
      assert length(name_keys) == 1
    end

    test "total key count does not grow when only overriding" do
      s = extend(base(), %{required(:name) => string(:filled?, min_length: 2),
                           required(:age)  => integer(gte?: 21)})
      assert length(s.keys) == length(base().keys)
    end
  end

  # ---------------------------------------------------------------------------
  # conform/2 with extended schema
  # ---------------------------------------------------------------------------

  describe "conform/2 with extended schema" do
    test "valid against base passes" do
      s = extend(base(), %{optional(:bio) => string()})
      assert {:ok, result} = conform(s, %{name: "Mark", email: "m@x.com", age: 33})
      assert result.name == "Mark"
    end

    test "new required field missing returns error" do
      s = extend(base(), %{required(:bio) => string(:filled?)})
      assert {:error, errors} = conform(s, %{name: "Mark", email: "m@x.com", age: 33})
      assert Enum.any?(errors, &(&1.path == [:bio]))
    end

    test "new optional field absent is omitted" do
      s = extend(base(), %{optional(:bio) => string()})
      assert {:ok, result} = conform(s, %{name: "Mark", email: "m@x.com", age: 33})
      refute Map.has_key?(result, :bio)
    end

    test "overridden spec is used for validation" do
      s = extend(base(), %{required(:age) => integer(gte?: 21)})
      # 18 passes base but fails extended
      assert {:error, errors} = conform(s, %{name: "Mark", email: "m@x.com", age: 18})
      assert Enum.any?(errors, &(&1.path == [:age]))
    end

    test "overridden spec passes with valid value" do
      s = extend(base(), %{required(:age) => integer(gte?: 21)})
      assert {:ok, %{age: 25}} = conform(s, %{name: "Mark", email: "m@x.com", age: 25})
    end

    test "coercions on extended fields work" do
      s = extend(base(), %{required(:age) => coerce(integer(gte?: 0), from: :string)})
      assert {:ok, %{age: 33}} =
               conform(s, %{name: "Mark", email: "m@x.com", age: "33"})
    end

    test "transforms on extended fields work" do
      s = extend(base(), %{required(:name) => transform(string(:filled?), &String.trim/1)})
      assert {:ok, %{name: "Mark"}} =
               conform(s, %{name: "  Mark  ", email: "m@x.com", age: 33})
    end

    test "defaults on extended optional fields work" do
      s = extend(base(), %{optional(:bio) => default(string(), "no bio")})
      assert {:ok, %{bio: "no bio"}} =
               conform(s, %{name: "Mark", email: "m@x.com", age: 33})
    end
  end

  # ---------------------------------------------------------------------------
  # Integration with selection/2
  # ---------------------------------------------------------------------------

  describe "extend/2 + selection/2" do
    test "create / update / patch pattern" do
      base_fields = schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(:filled?, format: ~r/@/),
        required(:age)   => integer(gte?: 0)
      })

      create = extend(base_fields, %{required(:password) => string(min_length: 8)})
      update = extend(base_fields, %{optional(:role) => atom(in?: [:admin, :user])})
      patch  = selection(update, [:name, :email, :age, :role])

      # Create requires password
      assert {:error, _} = conform(create, %{name: "Mark", email: "m@x.com", age: 33})
      assert {:ok, _}    = conform(create, %{name: "Mark", email: "m@x.com", age: 33,
                                              password: "secret123"})

      # Update allows role, doesn't require password
      assert {:ok, result} = conform(update, %{name: "Mark", email: "m@x.com",
                                                age: 33, role: :admin})
      assert result.role == :admin

      # Patch accepts any subset of update fields
      assert {:ok, %{name: "NewName"}} = conform(patch, %{name: "NewName"})
      assert {:ok, %{}}                = conform(patch, %{})
    end

    test "selection from extended schema inherits extended specs" do
      s = extend(base(), %{required(:age) => integer(gte?: 21)})
      patch = selection(s, [:age])

      # The tightened age constraint applies in the selection
      assert {:error, _} = conform(patch, %{age: 18})
      assert {:ok, _}    = conform(patch, %{age: 25})
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  describe "edge cases" do
    test "extending an already-extended schema" do
      once = extend(base(), %{optional(:bio) => string()})
      twice = extend(once, %{optional(:avatar) => string()})

      names = Enum.map(twice.keys, & &1.name)
      assert :bio    in names
      assert :avatar in names
      assert :name   in names
    end

    test "extend with nested schema" do
      address_schema = schema(%{
        required(:street) => string(:filled?),
        required(:zip)    => string(size?: 5)
      })
      s = extend(base(), %{optional(:address) => address_schema})

      assert {:ok, result} =
               conform(s, %{name: "Mark", email: "m@x.com", age: 33,
                             address: %{street: "1 Main", zip: "22701"}})
      assert result.address.street == "1 Main"
    end

    test "bare atom keys in extension map are treated as required" do
      s = extend(base(), %{bio: string()})
      key = Enum.find(s.keys, &(&1.name == :bio))
      assert key.required
    end

    test "valid?/2 and explain/2 work on extended schema" do
      s = extend(base(), %{required(:age) => integer(gte?: 21)})
      refute valid?(s, %{name: "Mark", email: "m@x.com", age: 18})
      result = explain(s, %{name: "Mark", email: "m@x.com", age: 18})
      refute result.valid?
    end
  end
end
