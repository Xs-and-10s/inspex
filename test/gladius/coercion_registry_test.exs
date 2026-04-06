defmodule Gladius.CoercionRegistryTest do
  # persistent_term is global state that can't be cleaned up between tests —
  # async: false prevents cross-test contamination.
  use ExUnit.Case, async: false

  import Gladius
  alias Gladius.Coercions

  # ---------------------------------------------------------------------------
  # register/2 and registered/0
  # ---------------------------------------------------------------------------

  describe "register/2" do
    test "registers a new coercion pair" do
      fun = fn v -> {:ok, v} end
      Coercions.register({:test_src_a, :test_tgt_a}, fun)
      assert Map.has_key?(Coercions.registered(), {:test_src_a, :test_tgt_a})
    end

    test "lookup/2 finds a user-registered coercion" do
      fun = fn v -> {:ok, inspect(v)} end
      Coercions.register({:test_src_b, :test_tgt_b}, fun)
      assert Coercions.lookup(:test_src_b, :test_tgt_b) == fun
    end

    test "coerce/2 works with a user-registered source type" do
      # Register a coercion from a custom :decimal-like source to float
      Coercions.register({:test_decimal, :float}, fn
        {dec, exp} when is_integer(dec) and is_integer(exp) ->
          {:ok, dec * :math.pow(10, exp) * 1.0}
        v when is_float(v) ->
          {:ok, v}
        v ->
          {:error, "cannot coerce #{inspect(v)} to float"}
      end)

      spec = coerce(float(), from: :test_decimal)
      assert {:ok, 314.0} = conform(spec, {314, 0})
      assert {:ok, 3.14}  = conform(spec, {314, -2})
      assert {:ok, 9.99}  = conform(spec, 9.99)
      assert {:error, _}  = conform(spec, "bad")
    end

    test "registered/0 returns a map" do
      assert is_map(Coercions.registered())
    end
  end

  # ---------------------------------------------------------------------------
  # User coercions shadow built-ins for the same pair
  # ---------------------------------------------------------------------------

  describe "user coercions shadow built-ins" do
    test "registering {unique_src, :integer} shadows no built-in but takes precedence" do
      custom_fn = fn v -> {:ok, v * 100} end
      Coercions.register({:test_centibel, :integer}, custom_fn)
      assert Coercions.lookup(:test_centibel, :integer) == custom_fn
    end

    test "user coercion for a built-in pair overrides default behaviour" do
      # Override :string → :integer to reject negative strings
      positive_only = fn
        v when is_binary(v) ->
          case Integer.parse(String.trim(v)) do
            {n, ""} when n >= 0 -> {:ok, n}
            _ -> {:error, "must be a non-negative integer string"}
          end
        v when is_integer(v) -> {:ok, v}
        v -> {:error, "cannot coerce #{inspect(v)}"}
      end

      # We register on a unique pair to avoid polluting :string → :integer
      # for other tests.  Shadowing of a real built-in is the same code path.
      Coercions.register({:test_pos_string, :integer}, positive_only)
      fun = Coercions.lookup(:test_pos_string, :integer)
      assert {:ok, 42}   = fun.("42")
      assert {:error, _} = fun.("-1")
      assert {:error, _} = fun.("bad")
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end: user-registered coercion through conform/2
  # ---------------------------------------------------------------------------

  describe "end-to-end with conform/2" do
    test "user-registered coercion validates and conforms" do
      # Register a coercion from a string UUID format to an atom identifier
      Coercions.register({:test_uuid_string, :atom}, fn
        v when is_binary(v) ->
          case String.match?(v, ~r/^\w+$/) do
            true  -> {:ok, String.to_atom("id_" <> v)}
            false -> {:error, "invalid identifier: #{inspect(v)}"}
          end
        v when is_atom(v) -> {:ok, v}
        v -> {:error, "cannot coerce #{inspect(v)}"}
      end)

      spec = coerce(atom(), from: :test_uuid_string)
      assert {:ok, :id_abc123} = conform(spec, "abc123")
      assert {:ok, :my_atom}   = conform(spec, :my_atom)
      assert {:error, _}       = conform(spec, "invalid-chars!")
    end

    test "user coercion in a schema field" do
      Coercions.register({:test_cents, :integer}, fn
        v when is_integer(v) -> {:ok, v}
        {:cents, n} when is_integer(n) -> {:ok, n}
        v -> {:error, "expected integer or {:cents, n}, got #{inspect(v)}"}
      end)

      params = schema(%{
        required(:price_cents) => coerce(integer(gte?: 0), from: :test_cents),
        required(:name)        => string(:filled?)
      })

      assert {:ok, %{price_cents: 999, name: "Widget"}} =
        conform(params, %{price_cents: {:cents, 999}, name: "Widget"})

      assert {:ok, %{price_cents: 500, name: "Gadget"}} =
        conform(params, %{price_cents: 500, name: "Gadget"})
    end
  end
end
