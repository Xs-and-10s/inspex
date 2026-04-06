defmodule Gladius.GenTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # StreamData (imported by ExUnitProperties) exports several names that clash
  # with Gladius's type builders: integer/0-2, float/0-2, string/0-2,
  # boolean/0, atom/0-1, list/0-2, list_of/1. We exclude those from the
  # Gladius import and use the Gladius. prefix for them explicitly in tests.
  #
  # Non-clashing Gladius functions (gen, valid?, conform, schema, ref, maybe,
  # any_of, all_of, not_spec, cond_spec, coerce, spec, nil_spec, any, etc.)
  # are imported freely.
  import Gladius, except: [
    integer: 0, integer: 1, integer: 2,
    float:   0, float:   1, float:   2,
    string:  0, string:  1, string:  2,
    boolean: 0,
    atom:    0, atom:    1,
    list:    0, list:    1, list:    2,
    list_of: 1,
    gen:     1   # also exported by ExUnitProperties
  ]

  # Short aliases for the clashing builders — keeps test bodies readable.
  defp i(cs \\ []),  do: Gladius.integer(cs)
  defp f(cs \\ []),  do: Gladius.float(cs)
  defp s(cs \\ []),  do: Gladius.string(cs)
  defp s(c, more),   do: Gladius.string(c, more)
  defp b(),          do: Gladius.boolean()
  defp a(cs),        do: Gladius.atom(cs)
  defp lo(el_spec),  do: Gladius.list_of(el_spec)
  defp g(spec),      do: Gladius.gen(spec)

  # ---------------------------------------------------------------------------
  # Helper: every generated value must conform to the spec.
  # ---------------------------------------------------------------------------
  defp assert_generates_valid(spec) do
    check all value <- g(spec) do
      assert valid?(spec, value),
             "generated #{inspect(value)} did not conform"
    end
  end

  # ===========================================================================
  # Primitive type generators
  # ===========================================================================

  describe "integer/1" do
    property "unbounded generates integers" do
      check all v <- g(i()) do
        assert is_integer(v)
      end
    end

    property "gte?: lower bound respected" do
      check all v <- g(i(gte?: 10)), do: assert v >= 10
    end

    property "gt?: exclusive lower bound" do
      check all v <- g(i(gt?: 10)), do: assert v > 10
    end

    property "lte?: upper bound respected" do
      check all v <- g(i(lte?: -5)), do: assert v <= -5
    end

    property "lt?: exclusive upper bound" do
      check all v <- g(i(lt?: 0)), do: assert v < 0
    end

    property "range: gt? + lt?" do
      check all v <- g(i(gt?: 0, lt?: 10)), do: assert v in 1..9
    end

    property "generated values always conform" do
      assert_generates_valid(i())
      assert_generates_valid(i(gt?: 0))
      assert_generates_valid(i(gte?: -10, lte?: 10))
    end
  end

  describe "float/1" do
    property "generates floats" do
      check all v <- g(f()), do: assert is_float(v)
    end

    property "bounded float" do
      check all v <- g(f(gte?: 0.0, lte?: 1.0)) do
        assert v >= 0.0 and v <= 1.0
      end
    end

    property "generated values always conform" do
      assert_generates_valid(f())
      assert_generates_valid(f(gte?: 0.0))
    end
  end

  describe "string/1" do
    property "generates strings" do
      check all v <- g(s()), do: assert is_binary(v)
    end

    property "filled?: non-empty only" do
      check all v <- g(s(:filled?)), do: assert byte_size(v) > 0
    end

    property "min_length: respected" do
      check all v <- g(s(min_length: 5)), do: assert byte_size(v) >= 5
    end

    property "max_length: respected" do
      check all v <- g(s(max_length: 3)), do: assert byte_size(v) <= 3
    end

    property "size?: exact length" do
      check all v <- g(s(size?: 7)), do: assert byte_size(v) == 7
    end

    property "format: generated values match the regex" do
      check all v <- g(s(:filled?, min_length: 1, max_length: 8, format: ~r/\A[a-z]+\z/)) do
        assert Regex.match?(~r/\A[a-z]+\z/, v)
      end
    end

    property "generated values always conform" do
      assert_generates_valid(s())
      assert_generates_valid(s(:filled?))
      assert_generates_valid(s(min_length: 2, max_length: 10))
    end
  end

  describe "boolean/0" do
    property "generates booleans" do
      check all v <- g(b()), do: assert is_boolean(v)
    end

    property "generates both true and false" do
      values = Enum.take(g(b()), 50)
      assert true  in values
      assert false in values
    end
  end

  describe "atom/1" do
    property "in?: picks only from the allowed set" do
      roles = [:admin, :user, :guest]
      check all v <- g(a(in?: roles)), do: assert v in roles
    end

    property "generated values always conform" do
      assert_generates_valid(a(in?: [:a, :b, :c]))
    end
  end

  describe "nil_spec/0" do
    property "always generates nil" do
      check all v <- g(nil_spec()), do: assert is_nil(v)
    end
  end

  describe "any/0" do
    property "generated values conform to any()" do
      check all v <- g(any()), do: assert valid?(any(), v)
    end
  end

  # ===========================================================================
  # Combinators
  # ===========================================================================

  describe "maybe/1" do
    property "generates nil and inner-spec values" do
      check all v <- g(maybe(i(gte?: 0))) do
        assert is_nil(v) or (is_integer(v) and v >= 0)
      end
    end

    property "generates nil sometimes and inner-spec values sometimes" do
      values = Enum.take(g(maybe(i())), 100)
      assert Enum.any?(values, &is_nil/1),     "expected some nils"
      assert Enum.any?(values, &is_integer/1), "expected some integers"
    end

    property "generated values always conform" do
      assert_generates_valid(maybe(s(:filled?)))
      assert_generates_valid(maybe(i(gt?: 0)))
    end
  end

  describe "any_of/1" do
    property "generates values from any branch" do
      sp = any_of([i(), s()])
      check all v <- g(sp), do: assert is_integer(v) or is_binary(v)
    end

    property "generated values always conform" do
      assert_generates_valid(any_of([i(), s(), b()]))
    end

    test "raises for empty any_of" do
      assert_raise Gladius.GeneratorError, fn -> g(any_of([])) end
    end
  end

  describe "all_of/1" do
    property "first spec provides domain, rest filter" do
      even_pos = all_of([i(), spec(&(&1 > 0)), spec(&(rem(&1, 2) == 0))])
      check all v <- g(even_pos) do
        assert is_integer(v) and v > 0 and rem(v, 2) == 0
      end
    end

    property "generated values always conform" do
      assert_generates_valid(all_of([i(gte?: 1), i(lte?: 100)]))
    end

    property "empty all_of generates any term" do
      check all v <- g(all_of([])), do: assert valid?(all_of([]), v)
    end
  end

  describe "list_of/1" do
    property "generates lists of the element type" do
      check all v <- g(lo(i(gt?: 0))) do
        assert is_list(v)
        assert Enum.all?(v, &(is_integer(&1) and &1 > 0))
      end
    end

    property "generated values always conform" do
      assert_generates_valid(lo(s(:filled?)))
      assert_generates_valid(lo(b()))
    end
  end

  # ===========================================================================
  # Schema generator
  # ===========================================================================

  describe "schema/1" do
    property "required keys always present with correct types" do
      sc = schema(%{required(:name) => s(:filled?), required(:age) => i(gte?: 0, lte?: 150)})
      check all v <- g(sc) do
        assert is_binary(v.name) and byte_size(v.name) > 0
        assert is_integer(v.age) and v.age in 0..150
      end
    end

    property "optional keys may or may not be present" do
      sc = schema(%{
        required(:id)    => i(gt?: 0),
        optional(:tag)   => s(:filled?),
        optional(:score) => f(gte?: 0.0, lte?: 10.0)
      })
      check all v <- g(sc) do
        assert Map.has_key?(v, :id)
        if Map.has_key?(v, :tag),   do: assert is_binary(v.tag) and byte_size(v.tag) > 0
        if Map.has_key?(v, :score), do: assert v.score >= 0.0 and v.score <= 10.0
      end
    end

    property "optional keys are sometimes included, sometimes omitted" do
      sc = schema(%{required(:id) => i(), optional(:name) => s()})
      values = Enum.take(g(sc), 100)
      assert Enum.any?(values, &Map.has_key?(&1, :name)),       "expected :name to appear sometimes"
      assert Enum.any?(values, &(not Map.has_key?(&1, :name))), "expected :name to be absent sometimes"
    end

    property "generated maps always conform" do
      sc = schema(%{
        required(:name)   => s(:filled?),
        required(:score)  => i(gte?: 0, lte?: 100),
        optional(:active) => b()
      })
      assert_generates_valid(sc)
    end

    property "nested schemas produce nested maps" do
      address = schema(%{required(:street) => s(:filled?), required(:zip) => s(size?: 5)})
      person  = schema(%{required(:name) => s(:filled?), required(:address) => address})
      check all v <- g(person) do
        assert is_binary(v.name) and byte_size(v.name) > 0
        assert is_map(v.address)
        assert byte_size(v.address.zip) == 5
      end
    end
  end

  # ===========================================================================
  # ref/1 generator
  # ===========================================================================

  describe "ref/1" do
    setup do
      on_exit(&Gladius.Registry.clear_local/0)
    end

    property "resolves from registry and generates" do
      Gladius.Registry.register_local(:gen_age, i(gte?: 0, lte?: 120))
      check all v <- g(ref(:gen_age)), do: assert is_integer(v) and v in 0..120
    end

    test "raises UndefinedSpecError for unregistered refs" do
      assert_raise Gladius.UndefinedSpecError, fn -> g(ref(:no_such_spec_xyzzy)) end
    end
  end

  # ===========================================================================
  # spec/2 :gen option
  # ===========================================================================

  describe "spec/2 with :gen option" do
    property "uses the explicit generator" do
      even_int = spec(
        fn x -> is_integer(x) and rem(x, 2) == 0 end,
        gen: StreamData.filter(StreamData.integer(), &(rem(&1, 2) == 0))
      )
      check all v <- g(even_int) do
        assert is_integer(v) and rem(v, 2) == 0
        assert valid?(even_int, v)
      end
    end

    test "raises GeneratorError for predicate-only spec without :gen" do
      assert_raise Gladius.GeneratorError, fn -> g(spec(fn x -> rem(x, 2) == 0 end)) end
    end

    test "raises GeneratorError for guard-style spec without :gen" do
      assert_raise Gladius.GeneratorError, fn -> g(spec(is_integer() and &(&1 > 0))) end
    end
  end

  # ===========================================================================
  # Non-inferable specs
  # ===========================================================================

  describe "non-inferable specs" do
    test "not_spec raises GeneratorError" do
      assert_raise Gladius.GeneratorError, fn -> g(not_spec(i())) end
    end

    test "cond_spec raises GeneratorError" do
      assert_raise Gladius.GeneratorError, fn -> g(cond_spec(&is_integer/1, i(), s())) end
    end
  end

  # ===========================================================================
  # Coercion + generator
  # ===========================================================================

  describe "coerce/2 and gen/1" do
    property "gen produces the target type, which conforms after (idempotent) coercion" do
      sp = coerce(i(gte?: 0), from: :string)
      check all v <- g(sp), do: assert valid?(sp, v)
    end
  end
end
