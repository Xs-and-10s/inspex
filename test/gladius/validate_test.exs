defmodule Gladius.ValidateTest do
  use ExUnit.Case, async: true

  import Gladius

  # Shared schema used across tests
  defp date_range_schema do
    schema(%{
      required(:start_date) => string(:filled?),
      required(:end_date)   => string(:filled?)
    })
    |> validate(fn %{start_date: s, end_date: e} ->
      if e >= s, do: :ok, else: {:error, :end_date, "must be on or after start date"}
    end)
  end

  # ---------------------------------------------------------------------------
  # validate/2 construction
  # ---------------------------------------------------------------------------

  describe "validate/2 construction" do
    test "returns a %Gladius.Validate{} struct" do
      s = schema(%{required(:x) => integer()}) |> validate(fn _ -> :ok end)
      assert %Gladius.Validate{} = s
    end

    test "stores the inner spec" do
      inner = schema(%{required(:x) => integer()})
      s = inner |> validate(fn _ -> :ok end)
      assert s.spec == inner
    end

    test "stores the rule function" do
      rule = fn _ -> :ok end
      s = schema(%{required(:x) => integer()}) |> validate(rule)
      assert s.rules == [rule]
    end

    test "chaining appends rules to the same struct — does not nest" do
      rule1 = fn _ -> :ok end
      rule2 = fn _ -> :ok end
      s =
        schema(%{required(:x) => integer()})
        |> validate(rule1)
        |> validate(rule2)

      assert %Gladius.Validate{} = s
      assert length(s.rules) == 2
      # Inner spec is the schema, not a nested %Validate{}
      assert %Gladius.Schema{} = s.spec
    end

    test "works with any conformable as inner spec" do
      assert %Gladius.Validate{} = integer() |> validate(fn _ -> :ok end)
      assert %Gladius.Validate{} = string() |> validate(fn _ -> :ok end)
      assert %Gladius.Validate{} = list_of(integer()) |> validate(fn _ -> :ok end)
    end
  end

  # ---------------------------------------------------------------------------
  # conform — inner spec fails, rules do not run
  # ---------------------------------------------------------------------------

  describe "conform/2 — inner spec fails" do
    test "inner spec errors pass through unchanged" do
      s = schema(%{required(:age) => integer(gte?: 18)})
        |> validate(fn _ -> {:error, :base, "should not run"} end)

      assert {:error, [error]} = conform(s, %{age: 15})
      assert error.path == [:age]
      refute error.message == "should not run"
    end

    test "rule is not called when inner spec fails" do
      called = :ets.new(:validate_called, [:set, :public])
      s = schema(%{required(:age) => integer(gte?: 18)})
        |> validate(fn _ ->
          :ets.insert(called, {:called, true})
          :ok
        end)

      conform(s, %{age: 15})
      assert :ets.lookup(called, :called) == []
    end

    test "missing required key prevents rules from running" do
      s = schema(%{required(:name) => string(:filled?), required(:age) => integer()})
        |> validate(fn _ -> {:error, :base, "should not appear"} end)

      {:error, errors} = conform(s, %{name: "Mark"})
      refute Enum.any?(errors, &(&1.message == "should not appear"))
    end
  end

  # ---------------------------------------------------------------------------
  # conform — rule return values
  # ---------------------------------------------------------------------------

  describe "conform/2 — rule return :ok" do
    test ":ok passes through with shaped output" do
      s = schema(%{required(:x) => integer()}) |> validate(fn _ -> :ok end)
      assert {:ok, %{x: 42}} = conform(s, %{x: 42})
    end
  end

  describe "conform/2 — {:error, field, message}" do
    test "produces error with correct path and message" do
      s = date_range_schema()
      assert {:error, [error]} = conform(s, %{start_date: "2024-02-01", end_date: "2024-01-01"})
      assert error.path == [:end_date]
      assert error.message == "must be on or after start date"
      assert error.predicate == :validate
    end

    test "valid input passes" do
      s = date_range_schema()
      assert {:ok, _} = conform(s, %{start_date: "2024-01-01", end_date: "2024-02-01"})
    end

    test "equal dates pass" do
      s = date_range_schema()
      assert {:ok, _} = conform(s, %{start_date: "2024-01-01", end_date: "2024-01-01"})
    end
  end

  describe "conform/2 — {:error, :base, message}" do
    test "produces root-level error with empty path" do
      s = schema(%{required(:password) => string(:filled?),
                   required(:confirm)  => string(:filled?)})
        |> validate(fn %{password: p, confirm: c} ->
          if p == c, do: :ok, else: {:error, :base, "passwords do not match"}
        end)

      assert {:error, [error]} = conform(s, %{password: "abc", confirm: "xyz"})
      assert error.path == []
      assert error.message == "passwords do not match"
    end
  end

  describe "conform/2 — {:error, [{field, message}]}" do
    test "produces multiple errors from one rule" do
      s = schema(%{
            required(:low)  => integer(),
            required(:high) => integer()
          })
        |> validate(fn %{low: l, high: h} ->
          errors = []
          errors = if l < 0,   do: [{:low,  "must be non-negative"} | errors], else: errors
          errors = if h > 100, do: [{:high, "must be <= 100"}       | errors], else: errors
          if errors == [], do: :ok, else: {:error, errors}
        end)

      assert {:error, errors} = conform(s, %{low: -1, high: 200})
      assert length(errors) == 2
      paths = Enum.map(errors, & &1.path)
      assert [:low]  in paths
      assert [:high] in paths
    end
  end

  # ---------------------------------------------------------------------------
  # conform — multiple rules, all run, errors accumulate
  # ---------------------------------------------------------------------------

  describe "conform/2 — multiple rules" do
    test "all rules run when inner spec passes" do
      s = schema(%{required(:n) => integer()})
        |> validate(fn %{n: n} ->
          if n > 0,   do: :ok, else: {:error, :n, "must be positive"}
        end)
        |> validate(fn %{n: n} ->
          if rem(n, 2) == 0, do: :ok, else: {:error, :n, "must be even"}
        end)

      # -3 fails both rules
      assert {:error, errors} = conform(s, %{n: -3})
      assert length(errors) == 2
    end

    test "second rule runs even when first rule fails" do
      calls = :ets.new(:validate_calls, [:bag, :public])

      s = schema(%{required(:x) => integer()})
        |> validate(fn _ ->
          :ets.insert(calls, {:rule, 1})
          {:error, :x, "rule 1 failed"}
        end)
        |> validate(fn _ ->
          :ets.insert(calls, {:rule, 2})
          {:error, :x, "rule 2 failed"}
        end)

      assert {:error, errors} = conform(s, %{x: 1})
      assert length(errors) == 2
      assert length(:ets.lookup(calls, :rule)) == 2
    end

    test "all rules pass — returns {:ok, shaped}" do
      s = schema(%{required(:n) => integer()})
        |> validate(fn %{n: n} -> if n > 0,   do: :ok, else: {:error, :n, "positive"} end)
        |> validate(fn %{n: n} -> if n < 100, do: :ok, else: {:error, :n, "< 100"} end)

      assert {:ok, %{n: 42}} = conform(s, %{n: 42})
    end
  end

  # ---------------------------------------------------------------------------
  # conform — rule raises
  # ---------------------------------------------------------------------------

  describe "conform/2 — rule raises" do
    test "exception is caught and returned as Gladius.Error" do
      s = schema(%{required(:x) => integer()})
        |> validate(fn _ -> raise "something went wrong" end)

      assert {:error, [error]} = conform(s, %{x: 1})
      assert error.predicate == :validate
      assert error.message =~ "validate rule raised"
      assert error.message =~ "something went wrong"
    end
  end

  # ---------------------------------------------------------------------------
  # conform — shaped output is what rules receive
  # ---------------------------------------------------------------------------

  describe "conform/2 — rules receive shaped (post-coercion/transform) values" do
    test "rule receives coerced values" do
      s = schema(%{required(:age) => coerce(integer(gte?: 0), from: :string)})
        |> validate(fn %{age: age} ->
          if is_integer(age), do: :ok, else: {:error, :age, "expected integer"}
        end)

      assert {:ok, %{age: 25}} = conform(s, %{age: "25"})
    end

    test "rule receives transformed values" do
      s = schema(%{required(:name) => transform(string(:filled?), &String.trim/1)})
        |> validate(fn %{name: name} ->
          if String.length(name) >= 2,
            do: :ok,
            else: {:error, :name, "must be at least 2 characters after trimming"}
        end)

      assert {:error, [error]} = conform(s, %{name: "  x  "})
      assert error.path == [:name]
    end
  end

  # ---------------------------------------------------------------------------
  # validate on non-schema conformables
  # ---------------------------------------------------------------------------

  describe "validate/2 on non-schema specs" do
    test "works on a primitive spec" do
      s = integer() |> validate(fn n -> if rem(n, 2) == 0, do: :ok, else: {:error, :base, "must be even"} end)
      assert {:ok, 4}  = conform(s, 4)
      assert {:error, _} = conform(s, 3)
    end

    test "works on list_of" do
      s = list_of(integer())
        |> validate(fn list ->
          if length(list) >= 2, do: :ok, else: {:error, :base, "need at least 2 items"}
        end)

      assert {:ok, [1, 2, 3]} = conform(s, [1, 2, 3])
      assert {:error, _}      = conform(s, [1])
    end
  end

  # ---------------------------------------------------------------------------
  # integration — validate inside schema field
  # ---------------------------------------------------------------------------

  describe "validate inside a schema field" do
    test "nested validate on a field value" do
      s = schema(%{
        required(:range) =>
          schema(%{required(:min) => integer(), required(:max) => integer()})
          |> validate(fn %{min: min, max: max} ->
            if max > min, do: :ok, else: {:error, :max, "must be greater than min"}
          end)
      })

      assert {:ok, %{range: %{min: 1, max: 10}}} =
               conform(s, %{range: %{min: 1, max: 10}})

      assert {:error, [error]} = conform(s, %{range: %{min: 5, max: 3}})
      assert error.path == [:range, :max]
    end
  end

  # ---------------------------------------------------------------------------
  # valid?/2 and explain/2
  # ---------------------------------------------------------------------------

  describe "valid?/2 and explain/2" do
    test "valid?/2 returns true when all rules pass" do
      assert valid?(date_range_schema(), %{start_date: "2024-01-01", end_date: "2024-02-01"})
    end

    test "valid?/2 returns false when a rule fails" do
      refute valid?(date_range_schema(), %{start_date: "2024-02-01", end_date: "2024-01-01"})
    end

    test "explain/2 includes rule errors in formatted output" do
      result = explain(date_range_schema(), %{start_date: "2024-02-01", end_date: "2024-01-01"})
      refute result.valid?
      assert result.formatted =~ "end_date"
    end
  end

  # ---------------------------------------------------------------------------
  # gen/1 and to_typespec/1 delegate to inner spec
  # ---------------------------------------------------------------------------

  describe "gen/1 and to_typespec/1" do
    test "gen/1 delegates to inner spec" do
      s = schema(%{required(:n) => integer(gte?: 0, lte?: 10)})
        |> validate(fn _ -> :ok end)

      assert %StreamData{} = Gladius.gen(s)
    end

    test "to_typespec/1 delegates to inner spec" do
      inner = schema(%{required(:n) => integer()})
      s = inner |> validate(fn _ -> :ok end)
      assert Gladius.to_typespec(s) == Gladius.to_typespec(inner)
    end
  end
end
