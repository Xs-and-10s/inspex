defmodule Gladius.CoercionTest do
  use ExUnit.Case, async: true

  import Gladius

  # ===========================================================================
  # coerce/2 with custom functions
  # ===========================================================================

  describe "coerce/2 — custom function" do
    test "transforms the value before validation" do
      spec = coerce(integer(), fn
        v when is_binary(v) ->
          case Integer.parse(v) do
            {n, ""} -> {:ok, n}
            _       -> {:error, "not an integer: #{inspect(v)}"}
          end
        v when is_integer(v) -> {:ok, v}
        v -> {:error, "cannot coerce #{inspect(v)}"}
      end)

      assert {:ok, 42}    = conform(spec, "42")   # string → integer
      assert {:ok, 42}    = conform(spec, 42)      # already integer
      assert {:error, _}  = conform(spec, "bad")   # coercion failure
      assert {:error, _}  = conform(spec, :atom)   # coercion failure
    end

    test "coercion failure produces predicate: :coerce error" do
      spec = coerce(integer(), fn _ -> {:error, "always fails"} end)
      assert {:error, [%{predicate: :coerce, message: "always fails"}]} = conform(spec, 42)
    end

    test "coercion runs before constraints" do
      # string → integer, then check gt?: 0
      spec = coerce(integer(gt?: 0), fn
        v when is_binary(v) -> {:ok, String.to_integer(v)}
        v -> {:ok, v}
      end)

      assert {:ok, 5}     = conform(spec, "5")
      assert {:error, _}  = conform(spec, "-1")   # coerces to -1, then gt? fails
    end

    test "coercion runs before type check" do
      # The coercion produces an integer; the spec is integer()
      spec = coerce(integer(), fn _ -> {:ok, 99} end)
      assert {:ok, 99} = conform(spec, "anything")
      assert {:ok, 99} = conform(spec, nil)
    end

    test "coercion error short-circuits — constraints not checked" do
      boom_constraint_spec = coerce(
        integer(gt?: 0),
        fn _ -> {:error, "coercion failed"} end
      )
      # Should get coerce error, not gt? error
      assert {:error, [%{predicate: :coerce}]} = conform(boom_constraint_spec, "bad")
    end
  end

  # ===========================================================================
  # coerce/2 with from: :string built-in shorthand
  # ===========================================================================

  describe "coerce(spec, from: :string) — integer" do
    setup do: {:ok, spec: coerce(integer(), from: :string)}

    test "coerces a valid integer string", %{spec: spec} do
      assert {:ok, 42}   = conform(spec, "42")
      assert {:ok, -7}   = conform(spec, "-7")
      assert {:ok, 0}    = conform(spec, "0")
    end

    test "passes an integer through unchanged", %{spec: spec} do
      assert {:ok, 42} = conform(spec, 42)
    end

    test "trims whitespace before parsing", %{spec: spec} do
      assert {:ok, 42} = conform(spec, "  42  ")
    end

    test "fails on non-integer string", %{spec: spec} do
      assert {:error, [%{predicate: :coerce}]} = conform(spec, "3.14")
      assert {:error, [%{predicate: :coerce}]} = conform(spec, "abc")
      assert {:error, [%{predicate: :coerce}]} = conform(spec, "")
    end

    test "fails on non-string, non-integer", %{spec: spec} do
      assert {:error, _} = conform(spec, :atom)
      assert {:error, _} = conform(spec, nil)
    end

    test "constraints apply after coercion" do
      spec = coerce(integer(gt?: 18), from: :string)
      assert {:ok, 21}   = conform(spec, "21")
      assert {:error, _} = conform(spec, "15")
    end
  end

  describe "coerce(spec, from: :string) — float" do
    setup do: {:ok, spec: coerce(float(), from: :string)}

    test "coerces a float string", %{spec: spec} do
      assert {:ok, 3.14} = conform(spec, "3.14")
      assert {:ok, -0.5} = conform(spec, "-0.5")
    end

    test "passes floats and integers through", %{spec: spec} do
      assert {:ok, 3.14} = conform(spec, 3.14)
      assert {:ok, 3.0}  = conform(spec, 3)     # integer → float
    end

    test "fails on non-numeric string", %{spec: spec} do
      assert {:error, [%{predicate: :coerce}]} = conform(spec, "abc")
    end
  end

  describe "coerce(spec, from: :string) — boolean" do
    setup do: {:ok, spec: coerce(boolean(), from: :string)}

    test "truthy strings", %{spec: spec} do
      for s <- ~w(true True TRUE 1 yes YES on ON) do
        assert {:ok, true} = conform(spec, s), "expected #{inspect(s)} to coerce to true"
      end
    end

    test "falsy strings", %{spec: spec} do
      for s <- ~w(false False FALSE 0 no NO off OFF) do
        assert {:ok, false} = conform(spec, s), "expected #{inspect(s)} to coerce to false"
      end
    end

    test "passes booleans through unchanged", %{spec: spec} do
      assert {:ok, true}  = conform(spec, true)
      assert {:ok, false} = conform(spec, false)
    end

    test "fails on unrecognised strings", %{spec: spec} do
      assert {:error, [%{predicate: :coerce}]} = conform(spec, "maybe")
      assert {:error, [%{predicate: :coerce}]} = conform(spec, "2")
    end
  end

  describe "coerce(spec, from: :string) — atom" do
    test "coerces a string to an existing atom" do
      # :ok and :error are always loaded
      spec = coerce(atom(), from: :string)
      assert {:ok, :ok}    = conform(spec, "ok")
      assert {:ok, :error} = conform(spec, "error")
    end

    test "passes atoms through unchanged" do
      spec = coerce(atom(), from: :string)
      assert {:ok, :ok} = conform(spec, :ok)
    end

    test "fails on non-existent atoms" do
      spec = coerce(atom(), from: :string)
      assert {:error, [%{predicate: :coerce}]} =
        conform(spec, "this_atom_certainly_does_not_exist_xyzzy_12345")
    end

    test "in?: constraint applies after coercion" do
      spec = coerce(atom(in?: [:admin, :user]), from: :string)
      assert {:ok, :admin} = conform(spec, "admin")
      assert {:ok, :user}  = conform(spec, "user")
      assert {:error, _}   = conform(spec, "superuser")
    end
  end

  # ===========================================================================
  # Composition
  # ===========================================================================

  describe "composition" do
    test "maybe(coerce(...)) — nil passes, string coerces, invalid fails" do
      spec = maybe(coerce(integer(), from: :string))
      assert {:ok, nil}   = conform(spec, nil)
      assert {:ok, 42}    = conform(spec, "42")
      assert {:ok, 42}    = conform(spec, 42)
      assert {:error, _}  = conform(spec, "bad")
    end

    test "coerce inside a schema — HTTP-params-style" do
      params_schema = schema(%{
        required(:age)    => coerce(integer(gte?: 18), from: :string),
        required(:active) => coerce(boolean(), from: :string),
        required(:score)  => coerce(float(gt?: 0.0), from: :string),
        optional(:role)   => coerce(atom(in?: [:admin, :user]), from: :string)
      })

      assert {:ok, result} = conform(params_schema, %{
        age: "25", active: "true", score: "9.5", role: "admin"
      })
      assert result.age    == 25
      assert result.active == true
      assert result.score  == 9.5
      assert result.role   == :admin
    end

    test "schema accumulates coercion errors alongside constraint errors" do
      params_schema = schema(%{
        required(:age)   => coerce(integer(gt?: 0), from: :string),
        required(:score) => coerce(float(), from: :string)
      })

      assert {:error, errors} = conform(params_schema, %{age: "bad", score: "also_bad"})
      paths = Enum.map(errors, & &1.path)
      assert [:age] in paths
      assert [:score] in paths
    end

    test "list_of with coercion — coerces each element" do
      spec = list_of(coerce(integer(), from: :string))
      assert {:ok, [1, 2, 3]}  = conform(spec, ["1", "2", "3"])
      assert {:ok, [1, 2, 3]}  = conform(spec, [1, 2, 3])        # already integers

      assert {:error, errors} = conform(spec, ["1", "bad", "3"])
      assert Enum.any?(errors, &(&1.path == [1] and &1.predicate == :coerce))
    end

    test "all_of with coercion on the first spec — coerced value flows through" do
      # Coerce string → integer, then check additional predicate
      spec = all_of([
        coerce(integer(), from: :string),
        spec(&(rem(&1, 2) == 0))    # must be even
      ])

      assert {:ok, 4}    = conform(spec, "4")
      assert {:error, _} = conform(spec, "3")   # odd
      assert {:error, _} = conform(spec, "bad") # coercion fails
    end
  end

  # ===========================================================================
  # Error shape
  # ===========================================================================

  describe "error shape" do
    test "coerce error includes original value in meta" do
      spec = coerce(integer(), fn _ -> {:error, "nope"} end)
      assert {:error, [err]} = conform(spec, "original")
      assert err.predicate == :coerce
      assert err.value == "original"
      assert err.meta.original == "original"
      assert err.message == "nope"
    end

    test "coerce error path propagates correctly through schema" do
      s = schema(%{required(:age) => coerce(integer(), from: :string)})
      assert {:error, [err]} = conform(s, %{age: "bad"})
      assert err.path == [:age]
      assert err.predicate == :coerce
    end
  end

  # ===========================================================================
  # Unknown built-in raises ArgumentError at build time
  # ===========================================================================

  describe "unknown built-in coercion" do
    test "raises ArgumentError for unsupported source type" do
      assert_raise ArgumentError, ~r/No coercion/, fn ->
        coerce(integer(), from: :json)
      end
    end
  end
  # ===========================================================================
  # from: :integer built-ins
  # ===========================================================================

  describe "coerce(spec, from: :integer) — float" do
    setup do: {:ok, spec: coerce(float(), from: :integer)}

    test "coerces integer to float", %{spec: spec} do
      assert {:ok, 42.0} = conform(spec, 42)
      assert {:ok, result} = conform(spec, 0)
      assert result == 0.0
      assert {:ok, -7.0} = conform(spec, -7)
    end

    test "passes float through unchanged", %{spec: spec} do
      assert {:ok, 3.14} = conform(spec, 3.14)
    end

    test "fails on non-integer, non-float", %{spec: spec} do
      assert {:error, [%{predicate: :coerce}]} = conform(spec, "42")
      assert {:error, [%{predicate: :coerce}]} = conform(spec, nil)
    end
  end

  describe "coerce(spec, from: :integer) — string" do
    setup do: {:ok, spec: coerce(string(), from: :integer)}

    test "coerces integer to string", %{spec: spec} do
      assert {:ok, "42"}  = conform(spec, 42)
      assert {:ok, "0"}   = conform(spec, 0)
      assert {:ok, "-7"}  = conform(spec, -7)
    end

    test "passes string through unchanged", %{spec: spec} do
      assert {:ok, "hello"} = conform(spec, "hello")
    end

    test "fails on non-integer, non-string", %{spec: spec} do
      assert {:error, [%{predicate: :coerce}]} = conform(spec, 3.14)
      assert {:error, [%{predicate: :coerce}]} = conform(spec, :atom)
    end
  end

  describe "coerce(spec, from: :integer) — boolean" do
    setup do: {:ok, spec: coerce(boolean(), from: :integer)}

    test "0 → false, 1 → true", %{spec: spec} do
      assert {:ok, false} = conform(spec, 0)
      assert {:ok, true}  = conform(spec, 1)
    end

    test "passes booleans through", %{spec: spec} do
      assert {:ok, true}  = conform(spec, true)
      assert {:ok, false} = conform(spec, false)
    end

    test "fails on integers other than 0 and 1", %{spec: spec} do
      assert {:error, [%{predicate: :coerce}]} = conform(spec, 2)
      assert {:error, [%{predicate: :coerce}]} = conform(spec, -1)
    end

    test "fails on non-integer, non-boolean", %{spec: spec} do
      assert {:error, [%{predicate: :coerce}]} = conform(spec, "true")
    end
  end

  # ===========================================================================
  # from: :atom built-ins
  # ===========================================================================

  describe "coerce(spec, from: :atom) — string" do
    setup do: {:ok, spec: coerce(string(), from: :atom)}

    test "coerces atom to string", %{spec: spec} do
      assert {:ok, "ok"}    = conform(spec, :ok)
      assert {:ok, "error"} = conform(spec, :error)
      assert {:ok, "admin"} = conform(spec, :admin)
    end

    test "passes string through unchanged", %{spec: spec} do
      assert {:ok, "hello"} = conform(spec, "hello")
    end

    test "fails on non-atom, non-string", %{spec: spec} do
      assert {:error, [%{predicate: :coerce}]} = conform(spec, 42)
      assert {:error, [%{predicate: :coerce}]} = conform(spec, nil)
    end
  end

  # ===========================================================================
  # from: :float built-ins
  # ===========================================================================

  describe "coerce(spec, from: :float) — integer" do
    setup do: {:ok, spec: coerce(integer(), from: :float)}

    test "truncates float toward zero", %{spec: spec} do
      assert {:ok, 3}  = conform(spec, 3.7)
      assert {:ok, 3}  = conform(spec, 3.0)
      assert {:ok, -3} = conform(spec, -3.7)
    end

    test "passes integer through unchanged", %{spec: spec} do
      assert {:ok, 42} = conform(spec, 42)
    end

    test "fails on non-float, non-integer", %{spec: spec} do
      assert {:error, [%{predicate: :coerce}]} = conform(spec, "3.7")
      assert {:error, [%{predicate: :coerce}]} = conform(spec, nil)
    end
  end

  describe "coerce(spec, from: :float) — string" do
    setup do: {:ok, spec: coerce(string(), from: :float)}

    test "coerces float to string", %{spec: spec} do
      assert {:ok, "3.14"} = conform(spec, 3.14)
      assert {:ok, "0.0"}  = conform(spec, 0.0)
    end

    test "passes string through unchanged", %{spec: spec} do
      assert {:ok, "hello"} = conform(spec, "hello")
    end

    test "fails on non-float, non-string", %{spec: spec} do
      assert {:error, [%{predicate: :coerce}]} = conform(spec, 42)
    end
  end

  # ===========================================================================
  # Unknown built-in — updated error message
  # ===========================================================================

  describe "unknown built-in — updated error message" do
    test "lists all built-in sources in the error" do
      assert_raise ArgumentError, fn ->
        coerce(integer(), from: :json)
      end
    end

    test "suggests register/2 in the error message" do
      try do
        coerce(integer(), from: :decimal)
      rescue
        e in ArgumentError ->
          assert Exception.message(e) =~ "register"
      end
    end
  end
end
