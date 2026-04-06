defmodule GladiusTest do
  use ExUnit.Case, async: true

  import Gladius

  # ===========================================================================
  # Primitive type specs
  # ===========================================================================

  describe "string/1" do
    test "passes a plain string" do
      assert {:ok, "hello"} = conform(string(), "hello")
    end

    test "rejects a non-string" do
      assert {:error, [%{predicate: :type?, message: msg}]} = conform(string(), 42)
      assert msg =~ "string"
    end

    test ":filled? rejects empty string" do
      assert {:error, [%{predicate: :filled?}]} = conform(string(:filled?), "")
    end

    test ":filled? passes non-empty string" do
      assert {:ok, "hi"} = conform(string(:filled?), "hi")
    end

    test "format: constraint" do
      email_spec = string(format: ~r/@/)
      assert {:ok, "a@b.com"} = conform(email_spec, "a@b.com")
      assert {:error, [%{predicate: :format}]} = conform(email_spec, "notanemail")
    end

    test "multiple constraints are all checked" do
      spec = string(:filled?, min_length: 3, max_length: 10)
      assert {:ok, "hello"} = conform(spec, "hello")
      assert {:error, errs} = conform(spec, "")
      # filled? and min_length both fire
      assert Enum.any?(errs, &(&1.predicate == :filled?))
      assert Enum.any?(errs, &(&1.predicate == :min_length))
    end
  end

  describe "integer/1" do
    test "passes an integer" do
      assert {:ok, 42} = conform(integer(), 42)
    end

    test "rejects a float" do
      assert {:error, [%{predicate: :type?}]} = conform(integer(), 3.14)
    end

    test "gt? constraint" do
      assert {:ok, 19} = conform(integer(gt?: 18), 19)
      assert {:error, [%{predicate: :gt?}]} = conform(integer(gt?: 18), 18)
      assert {:error, [%{predicate: :gt?}]} = conform(integer(gt?: 18), 10)
    end

    test "gte? constraint" do
      assert {:ok, 18} = conform(integer(gte?: 18), 18)
      assert {:error, [%{predicate: :gte?}]} = conform(integer(gte?: 18), 17)
    end

    test "lte? and lt? constraints" do
      assert {:ok, 99} = conform(integer(lte?: 100), 99)
      assert {:error, [%{predicate: :lte?}]} = conform(integer(lte?: 100), 101)
      assert {:ok, 99} = conform(integer(lt?: 100), 99)
      assert {:error, [%{predicate: :lt?}]} = conform(integer(lt?: 100), 100)
    end
  end

  describe "float/1" do
    test "passes a float" do
      assert {:ok, 3.14} = conform(float(), 3.14)
    end

    test "rejects an integer" do
      assert {:error, [%{predicate: :type?}]} = conform(float(), 3)
    end
  end

  describe "boolean/0" do
    test "passes true and false" do
      assert {:ok, true}  = conform(boolean(), true)
      assert {:ok, false} = conform(boolean(), false)
    end

    test "rejects truthy non-booleans" do
      assert {:error, _} = conform(boolean(), 1)
      assert {:error, _} = conform(boolean(), "true")
    end
  end

  describe "atom/1" do
    test "passes atoms" do
      assert {:ok, :foo} = conform(atom(), :foo)
    end

    test "in? constraint" do
      role = atom(in?: [:admin, :user, :guest])
      assert {:ok, :admin} = conform(role, :admin)
      assert {:error, [%{predicate: :in?}]} = conform(role, :superuser)
    end
  end

  describe "nil_spec/0" do
    test "passes nil" do
      assert {:ok, nil} = conform(nil_spec(), nil)
    end

    test "rejects non-nil" do
      assert {:error, [%{predicate: :type?}]} = conform(nil_spec(), false)
      assert {:error, _} = conform(nil_spec(), "")
    end
  end

  describe "any/0" do
    test "accepts literally anything" do
      for value <- [nil, 42, "hi", :ok, [], %{}, {1, 2}] do
        assert {:ok, ^value} = conform(any(), value)
      end
    end
  end

  # ===========================================================================
  # spec/1 macro
  # ===========================================================================

  describe "spec/1" do
    test "function capture form" do
      assert {:ok, 5} = conform(spec(&is_integer/1), 5)
      assert {:error, _} = conform(spec(&is_integer/1), "5")
    end

    test "anonymous function form" do
      even = spec(fn x -> is_integer(x) and rem(x, 2) == 0 end)
      assert {:ok, 4} = conform(even, 4)
      assert {:error, _} = conform(even, 3)
      assert {:error, _} = conform(even, "4")
    end

    test "guard shorthand: spec(is_integer())" do
      assert {:ok, 1} = conform(spec(is_integer()), 1)
      assert {:error, _} = conform(spec(is_integer()), "1")
    end

    test "guard + capture composition: spec(is_integer() and &(&1 > 0))" do
      pos_int = spec(is_integer() and &(&1 > 0))
      assert {:ok, 1} = conform(pos_int, 1)
      assert {:error, _} = conform(pos_int, 0)
      assert {:error, _} = conform(pos_int, -1)
      assert {:error, _} = conform(pos_int, "1")
    end

    test "triple composition via fn literal" do
      # Two & captures in a single and-chain hit an Elixir compiler restriction
      # (nested captures). Use a fn literal instead, or compose with all_of/1.
      positive_even_int = spec(fn x -> is_integer(x) and x > 0 and rem(x, 2) == 0 end)

      assert {:ok, 4} = conform(positive_even_int, 4)
      assert {:error, _} = conform(positive_even_int, 3)    # odd
      assert {:error, _} = conform(positive_even_int, -2)   # negative
      assert {:error, _} = conform(positive_even_int, 2.0)  # float
    end

    test "triple composition via all_of is the idiomatic gladius approach" do
      positive_even_int =
        all_of([spec(is_integer()), spec(&(&1 > 0)), spec(&(rem(&1, 2) == 0))])

      assert {:ok, 4} = conform(positive_even_int, 4)
      assert {:error, _} = conform(positive_even_int, 3)
      assert {:error, _} = conform(positive_even_int, -2)
      assert {:error, _} = conform(positive_even_int, 2.0)
    end

    test "error message includes source expression" do
      s = spec(is_binary() and &(byte_size(&1) > 5))
      assert {:error, [%{message: msg}]} = conform(s, 42)
      assert msg =~ "is_binary"
    end
  end

  # ===========================================================================
  # Combinators
  # ===========================================================================

  describe "all_of/1" do
    test "all must pass" do
      s = all_of([integer(), spec(&(&1 > 0)), spec(&(rem(&1, 2) == 0))])
      assert {:ok, 4} = conform(s, 4)
      assert {:error, _} = conform(s, -2)
      assert {:error, _} = conform(s, 3)
    end

    test "pipelines shaped output through specs" do
      # In Step 3, coercions will make this interesting. For now, value passes through.
      s = all_of([integer(), integer(gt?: 0)])
      assert {:ok, 5} = conform(s, 5)
    end

    test "empty all_of is vacuously true" do
      assert {:ok, "anything"} = conform(all_of([]), "anything")
    end

    test "short-circuits on first failure" do
      # If the second spec raises on non-integers, we should never reach it
      # because the first spec fails first.
      boom = spec(fn _ -> raise "should not be called" end)
      s = all_of([integer(), boom])
      assert {:error, _} = conform(s, "not an int")
    end
  end

  describe "any_of/1" do
    test "first match wins" do
      s = any_of([integer(), string()])
      assert {:ok, 42} = conform(s, 42)
      assert {:ok, "hello"} = conform(s, "hello")
    end

    test "all must fail for error" do
      s = any_of([integer(), string()])
      assert {:error, _} = conform(s, :an_atom)
    end

    test "empty any_of always fails" do
      assert {:error, _} = conform(any_of([]), "anything")
    end
  end

  describe "not_spec/1" do
    test "inverts conformance" do
      not_int = not_spec(integer())
      assert {:ok, "hello"} = conform(not_int, "hello")
      assert {:ok, :foo}    = conform(not_int, :foo)
      assert {:error, _}    = conform(not_int, 42)
    end

    test "passes value through unchanged on success" do
      assert {:ok, "unchanged"} = conform(not_spec(integer()), "unchanged")
    end
  end

  describe "maybe/1" do
    test "nil always passes" do
      assert {:ok, nil} = conform(maybe(string(:filled?)), nil)
    end

    test "non-nil is delegated to inner spec" do
      assert {:ok, "hi"}  = conform(maybe(string(:filled?)), "hi")
      assert {:error, _}  = conform(maybe(string(:filled?)), "")
      assert {:error, _}  = conform(maybe(string(:filled?)), 42)
    end
  end

  # ===========================================================================
  # list_of/1
  # ===========================================================================

  describe "list_of/1" do
    test "passes a valid typed list" do
      assert {:ok, [1, 2, 3]} = conform(list_of(integer()), [1, 2, 3])
    end

    test "rejects non-list input" do
      assert {:error, [%{predicate: :type?}]} = conform(list_of(integer()), "not a list")
    end

    test "accumulates errors from all elements" do
      s = list_of(integer(gt?: 0))
      assert {:error, errors} = conform(s, [1, -1, 2, -3])
      # Errors for indices 1 and 3
      paths = Enum.map(errors, & &1.path)
      assert [1] in paths
      assert [3] in paths
      refute [0] in paths
      refute [2] in paths
    end

    test "paths include the element index" do
      assert {:error, errors} = conform(list_of(integer()), ["bad", 42, "also_bad"])
      paths = Enum.map(errors, & &1.path)
      assert [0] in paths
      assert [2] in paths
      refute [1] in paths
    end

    test "nested list paths" do
      s = list_of(schema(%{required(:x) => integer()}))
      assert {:error, errors} = conform(s, [%{x: 1}, %{x: "bad"}, %{x: 3}])
      # Should have path [1, :x]
      assert Enum.any?(errors, &(&1.path == [1, :x]))
    end
  end

  # ===========================================================================
  # cond_spec/3
  # ===========================================================================

  describe "cond_spec/3" do
    test "applies if_spec when predicate is truthy" do
      s = cond_spec(&is_integer/1, integer(gt?: 0), string())
      assert {:ok, 5}       = conform(s, 5)
      assert {:error, _}    = conform(s, -1)   # predicate true but gt? fails
    end

    test "applies else_spec when predicate is falsy" do
      s = cond_spec(&is_integer/1, integer(gt?: 0), string(:filled?))
      assert {:ok, "hello"} = conform(s, "hello")
      assert {:error, _}    = conform(s, "")
    end

    test "else_spec defaults to any() — passthrough" do
      s = cond_spec(&is_integer/1, integer(gt?: 0))
      assert {:ok, "anything"} = conform(s, "anything")  # predicate false, else = any()
      assert {:ok, 5}          = conform(s, 5)
      assert {:error, _}       = conform(s, -1)
    end
  end

  # ===========================================================================
  # schema/1 and open_schema/1
  # ===========================================================================

  describe "schema/1 — basic" do
    setup do
      user = schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(format: ~r/@/),
        optional(:age)   => integer(gte?: 0)
      })
      {:ok, schema: user}
    end

    test "passes a valid map", %{schema: s} do
      assert {:ok, %{name: "Mark", email: "m@x.com"}} =
        conform(s, %{name: "Mark", email: "m@x.com"})
    end

    test "optional keys may be absent", %{schema: s} do
      assert {:ok, _} = conform(s, %{name: "Mark", email: "m@x.com"})
    end

    test "optional keys are included when present", %{schema: s} do
      assert {:ok, %{age: 33}} = conform(s, %{name: "Mark", email: "m@x.com", age: 33})
    end

    test "missing required key produces an error", %{schema: s} do
      assert {:error, errors} = conform(s, %{name: "Mark"})
      assert Enum.any?(errors, &(&1.predicate == :has_key? and &1.path == [:email]))
    end

    test "field type failure includes the field path", %{schema: s} do
      assert {:error, errors} = conform(s, %{name: "Mark", email: 123})
      assert Enum.any?(errors, &(&1.path == [:email] and &1.predicate == :type?))
    end

    test "accumulates ALL errors across all fields", %{schema: s} do
      assert {:error, errors} = conform(s, %{name: "", age: -1})
      paths = Enum.map(errors, & &1.path)
      assert [:name] in paths    # name failed :filled?
      assert [:email] in paths   # email missing
      assert [:age] in paths     # age failed gte?
    end

    test "rejects unknown keys (closed schema)", %{schema: s} do
      assert {:error, errors} = conform(s, %{name: "Mark", email: "m@x.com", unknown: "hi"})
      assert Enum.any?(errors, &(&1.predicate == :unknown_key?))
    end

    test "rejects non-map input", %{schema: s} do
      assert {:error, [%{predicate: :type?}]} = conform(s, "not a map")
    end
  end

  describe "open_schema/1" do
    test "passes extra keys through unchanged" do
      s = open_schema(%{required(:name) => string()})
      assert {:ok, %{name: "Mark", extra: "value"}} =
        conform(s, %{name: "Mark", extra: "value"})
    end

    test "still validates declared keys" do
      s = open_schema(%{required(:name) => string(:filled?)})
      assert {:error, _} = conform(s, %{name: "", extra: "value"})
    end
  end

  describe "schema/1 — nested" do
    test "nested schemas produce nested error paths" do
      address = schema(%{
        required(:street) => string(:filled?),
        required(:zip)    => string(size?: 5)
      })
      person = schema(%{
        required(:name)    => string(:filled?),
        required(:address) => address
      })

      assert {:error, errors} = conform(person, %{
        name: "Mark",
        address: %{street: "Main St", zip: "123"}   # zip too short
      })

      assert Enum.any?(errors, &(&1.path == [:address, :zip]))
    end

    test "list_of inside a schema" do
      s = schema(%{
        required(:tags) => list_of(string(:filled?))
      })

      assert {:ok, %{tags: ["a", "b"]}} = conform(s, %{tags: ["a", "b"]})

      assert {:error, errors} = conform(s, %{tags: ["a", "", "b"]})
      assert Enum.any?(errors, &(&1.path == [:tags, 1]))
    end
  end

  describe "schema/1 — bare atom keys (required shorthand)" do
    test "bare atom keys default to required" do
      s = schema(%{name: string(), age: integer()})
      assert {:ok, %{name: "Mark", age: 33}} = conform(s, %{name: "Mark", age: 33})
      assert {:error, errors} = conform(s, %{name: "Mark"})
      assert Enum.any?(errors, &(&1.path == [:age]))
    end
  end

  # ===========================================================================
  # valid?/2
  # ===========================================================================

  describe "valid?/2" do
    test "returns true on success" do
      assert valid?(string(), "hello")
    end

    test "returns false on failure" do
      refute valid?(string(), 42)
    end
  end

  # ===========================================================================
  # explain/2
  # ===========================================================================

  describe "explain/2" do
    test "valid result" do
      result = explain(string(), "hello")
      assert result.valid? == true
      assert result.errors == []
      assert result.formatted == "ok"
    end

    test "invalid result includes formatted string" do
      s = schema(%{required(:name) => string(:filled?), required(:age) => integer()})
      result = explain(s, %{name: "", age: "old"})
      assert result.valid? == false
      assert length(result.errors) == 2
      assert result.formatted =~ ":name"
      assert result.formatted =~ ":age"
    end
  end

  # ===========================================================================
  # Error string representation
  # ===========================================================================

  describe "Gladius.Error — String.Chars" do
    test "root-level error (empty path)" do
      err = %Gladius.Error{path: [], message: "must be a map"}
      assert to_string(err) == "must be a map"
    end

    test "single-key path" do
      err = %Gladius.Error{path: [:name], message: "must be filled"}
      assert to_string(err) == ":name: must be filled"
    end

    test "nested key path" do
      err = %Gladius.Error{path: [:user, :address, :zip], message: "must be 5 chars"}
      assert to_string(err) == ":user.:address.:zip: must be 5 chars"
    end

    test "path with list index" do
      err = %Gladius.Error{path: [:tags, 2], message: "must be filled"}
      assert to_string(err) == ":tags.[2]: must be filled"
    end
  end

  # ===========================================================================
  # Ref — registry (process-dictionary implementation)
  # ===========================================================================

  describe "ref/1 — registry" do
    setup do
      on_exit(fn -> Gladius.Registry.clear() end)
      :ok
    end

    test "resolves a registered spec" do
      Gladius.Registry.register(:pos_int, integer(gt?: 0))
      assert {:ok, 5}  = conform(ref(:pos_int), 5)
      assert {:error, _} = conform(ref(:pos_int), -1)
      assert {:error, _} = conform(ref(:pos_int), "5")
    end

    test "raises a structured error for unregistered names" do
      assert {:error, [%{message: msg}]} = conform(ref(:no_such_spec), "anything")
      assert msg =~ "no_such_spec"
    end

    test "ref inside a schema" do
      Gladius.Registry.register(:email, string(:filled?, format: ~r/@/))

      user = schema(%{
        required(:name)  => string(:filled?),
        required(:email) => ref(:email)
      })

      assert {:ok, _} = conform(user, %{name: "Mark", email: "m@x.com"})
      assert {:error, errors} = conform(user, %{name: "Mark", email: "notanemail"})
      assert Enum.any?(errors, &(&1.path == [:email]))
    end

    test "registration overwrites previous value" do
      Gladius.Registry.register(:x, integer())
      Gladius.Registry.register(:x, string())
      assert {:ok, "hi"} = conform(ref(:x), "hi")
      assert {:error, _} = conform(ref(:x), 42)
    end
  end

  # ===========================================================================
  # Composition examples (integration)
  # ===========================================================================

  describe "composition" do
    test "nullable typed list" do
      s = maybe(list_of(string(:filled?)))
      assert {:ok, nil}          = conform(s, nil)
      assert {:ok, ["a", "b"]}   = conform(s, ["a", "b"])
      assert {:error, _}         = conform(s, ["a", ""])
    end

    test "union of schemas" do
      cat = schema(%{required(:type) => atom(in?: [:cat]), required(:indoor) => boolean()})
      dog = schema(%{required(:type) => atom(in?: [:dog]), required(:breed)  => string()})
      pet = any_of([cat, dog])

      assert {:ok, _} = conform(pet, %{type: :cat, indoor: true})
      assert {:ok, _} = conform(pet, %{type: :dog, breed: "labrador"})
      assert {:error, _} = conform(pet, %{type: :fish})
    end

    test "all_of narrowing" do
      # A non-empty list of non-empty strings, max 5 items
      s = all_of([
        list(:filled?),                             # non-empty list
        list_of(string(:filled?)),                  # elements are non-empty strings
        spec(&(length(&1) <= 5))                    # at most 5 items
      ])

      assert {:ok, ["a", "b"]} = conform(s, ["a", "b"])
      assert {:error, _} = conform(s, [])                            # filled? fails
      assert {:error, _} = conform(s, ["a", ""])                     # element fails
      assert {:error, _} = conform(s, ["a", "b", "c", "d", "e", "f"]) # length fails
    end
  end
end
