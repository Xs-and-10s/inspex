defmodule Gladius.TransformTest do
  use ExUnit.Case, async: true

  import Gladius

  # ---------------------------------------------------------------------------
  # transform/2 construction
  # ---------------------------------------------------------------------------

  describe "transform/2" do
    test "returns a %Gladius.Transform{} struct" do
      spec = transform(string(:filled?), &String.trim/1)
      assert %Gladius.Transform{} = spec
      assert %Gladius.Spec{} = spec.spec
      assert is_function(spec.fun, 1)
    end

    test "accepts any conformable as inner spec" do
      assert %Gladius.Transform{} = transform(string(:filled?), &String.trim/1)
      assert %Gladius.Transform{} = transform(integer(gte?: 0), &(&1 * 2))
      assert %Gladius.Transform{} = transform(maybe(string()), &Function.identity/1)
      assert %Gladius.Transform{} = transform(list_of(integer()), &Enum.sort/1)
      assert %Gladius.Transform{} = transform(schema(%{required(:x) => integer()}), & &1)
    end

    test "accepts any arity-1 function" do
      assert %Gladius.Transform{} = transform(string(), fn s -> String.upcase(s) end)
      assert %Gladius.Transform{} = transform(string(), &String.upcase/1)
    end
  end

  # ---------------------------------------------------------------------------
  # conform — happy path
  # ---------------------------------------------------------------------------

  describe "conform/2 — transform applied after validation" do
    test "transforms a valid string" do
      spec = transform(string(:filled?), &String.trim/1)
      assert {:ok, "hello"} = conform(spec, "  hello  ")
    end

    test "downcases email" do
      spec = transform(string(:filled?, format: ~r/@/), &String.downcase/1)
      assert {:ok, "mark@example.com"} = conform(spec, "MARK@EXAMPLE.COM")
    end

    test "doubles an integer" do
      spec = transform(integer(gte?: 0), &(&1 * 2))
      assert {:ok, 84} = conform(spec, 42)
    end

    test "transforms a list" do
      spec = transform(list_of(integer()), &Enum.sort/1)
      assert {:ok, [1, 2, 3]} = conform(spec, [3, 1, 2])
    end

    test "transforms a schema output" do
      spec = transform(
        schema(%{required(:name) => string(:filled?)}),
        fn m -> Map.put(m, :upcased, String.upcase(m.name)) end
      )
      assert {:ok, %{name: "mark", upcased: "MARK"}} = conform(spec, %{name: "mark"})
    end

    test "transform receives the coerced value, not the raw value" do
      spec = transform(coerce(integer(), from: :string), &(&1 + 1))
      assert {:ok, 43} = conform(spec, "42")
    end

    test "nil passes through maybe before transform" do
      spec = transform(maybe(string()), fn
        nil -> "default"
        s   -> String.upcase(s)
      end)
      assert {:ok, "default"} = conform(spec, nil)
      assert {:ok, "HELLO"} = conform(spec, "hello")
    end
  end

  # ---------------------------------------------------------------------------
  # conform — validation fails → transform never runs
  # ---------------------------------------------------------------------------

  describe "conform/2 — validation failure" do
    test "returns error without running transform when value is invalid" do
      side_effect = :ets.new(:transform_test_side, [:set, :public])
      spec = transform(string(:filled?), fn s ->
        :ets.insert(side_effect, {:called, true})
        s
      end)

      assert {:error, [_]} = conform(spec, "")
      assert :ets.lookup(side_effect, :called) == []
    end

    test "error path is preserved from inner spec" do
      spec = transform(integer(gte?: 18), &(&1 * 2))
      assert {:error, [error]} = conform(spec, 15)
      assert error.path == []
      assert error.message =~ "18"
    end

    test "schema errors are passed through unchanged" do
      spec = transform(
        schema(%{required(:age) => integer(gte?: 18)}),
        & &1
      )
      assert {:error, [error]} = conform(spec, %{age: 15})
      assert error.path == [:age]
    end

    test "wrong type returns type error, not transform error" do
      spec = transform(string(:filled?), &String.upcase/1)
      assert {:error, [error]} = conform(spec, 42)
      assert error.predicate == :type?
    end
  end

  # ---------------------------------------------------------------------------
  # conform — transform raises
  # ---------------------------------------------------------------------------

  describe "conform/2 — transform raises" do
    test "exception is caught and returned as Gladius.Error" do
      spec = transform(string(:filled?), fn _ -> raise "boom" end)
      assert {:error, [error]} = conform(spec, "hello")
      assert error.predicate == :transform
      assert error.message =~ "transform failed"
      assert error.message =~ "boom"
    end

    test "ArithmeticError is caught" do
      spec = transform(integer(), fn n -> div(n, 0) end)
      assert {:error, [error]} = conform(spec, 5)
      assert error.predicate == :transform
    end

    test "the value at time of failure is recorded on the error" do
      spec = transform(string(:filled?), fn s ->
        raise "bad value: #{s}"
      end)
      assert {:error, [error]} = conform(spec, "hello")
      assert error.value == "hello"
    end

    test "transform error has empty path — path is prepended by schema" do
      spec = transform(string(:filled?), fn _ -> raise "oops" end)
      assert {:error, [error]} = conform(spec, "hello")
      assert error.path == []
    end
  end

  # ---------------------------------------------------------------------------
  # schema integration
  # ---------------------------------------------------------------------------

  describe "transform inside schema" do
    test "transform on a field — happy path" do
      s = schema(%{
        required(:name)  => transform(string(:filled?), &String.trim/1),
        required(:email) => transform(string(:filled?, format: ~r/@/), &String.downcase/1)
      })

      assert {:ok, %{name: "Mark", email: "mark@x.com"}} =
               conform(s, %{name: "  Mark  ", email: "MARK@X.COM"})
    end

    test "error path includes field name when transform raises inside schema" do
      s = schema(%{
        required(:name) => transform(string(:filled?), fn _ -> raise "bad" end)
      })

      assert {:error, [error]} = conform(s, %{name: "Mark"})
      assert error.path == [:name]
      assert error.predicate == :transform
    end

    test "transform on optional field with default — default bypasses transform" do
      s = schema(%{
        optional(:name) => default(transform(string(:filled?), &String.trim/1), "anon")
      })

      # key absent — default injected directly, transform not run
      assert {:ok, %{name: "anon"}} = conform(s, %{})
      # key present — transform runs
      assert {:ok, %{name: "Mark"}} = conform(s, %{name: "  Mark  "})
    end

    test "accumulates transform errors alongside other errors" do
      s = schema(%{
        required(:name)  => transform(string(:filled?), fn _ -> raise "bad" end),
        required(:email) => string(:filled?, format: ~r/@/)
      })

      assert {:error, errors} = conform(s, %{name: "Mark", email: "not-an-email"})
      assert length(errors) == 2
      assert Enum.any?(errors, &(&1.predicate == :transform))
      assert Enum.any?(errors, &(&1.predicate == :format))
    end
  end

  # ---------------------------------------------------------------------------
  # composability
  # ---------------------------------------------------------------------------

  describe "composability" do
    test "transform chained with another transform" do
      spec =
        string(:filled?)
        |> transform(&String.trim/1)
        |> transform(&String.downcase/1)

      assert {:ok, "hello world"} = conform(spec, "  HELLO WORLD  ")
    end

    test "transform wrapping a list_of" do
      spec = transform(list_of(integer()), &Enum.uniq/1)
      assert {:ok, [1, 2, 3]} = conform(spec, [1, 2, 1, 3, 2])
    end

    test "transform inside all_of" do
      spec = all_of([
        integer(gte?: 0),
        transform(integer(), &(&1 * 10))
      ])
      assert {:ok, 50} = conform(spec, 5)
    end

    test "transform inside ref" do
      Gladius.Registry.register(
        :trimmed_name,
        transform(string(:filled?), &String.trim/1)
      )
      assert {:ok, "Mark"} = conform(ref(:trimmed_name), "  Mark  ")
    end
  end

  # ---------------------------------------------------------------------------
  # gen/1 and to_typespec/1 delegate to inner spec
  # ---------------------------------------------------------------------------

  describe "gen/1" do
    test "delegates to inner spec's generator" do
      spec = transform(integer(gte?: 0, lte?: 100), &(&1 * 2))
      assert %StreamData{} = Gladius.gen(spec)
    end
  end

  describe "to_typespec/1" do
    test "delegates to inner spec's typespec" do
      spec = transform(integer(), &(&1 * 2))
      assert Gladius.to_typespec(spec) == Gladius.to_typespec(integer())
    end
  end
end
