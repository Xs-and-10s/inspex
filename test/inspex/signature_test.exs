defmodule Inspex.SignatureTest do
  use ExUnit.Case, async: true

  # ===========================================================================
  # Test subject modules
  #
  # We define helper modules inside the test file using Module.create or
  # inline module definitions. Each module uses `use Inspex.Signature` so the
  # def override is scoped only to that module — it does NOT affect the test
  # module itself.
  # ===========================================================================

  # ---------------------------------------------------------------------------
  # Basic: args and ret
  # ---------------------------------------------------------------------------
  defmodule BasicSubject do
    use Inspex.Signature

    signature args: [string(:filled?), integer(gte?: 0)],
              ret:  string(:filled?)
    def greet(name, count) do
      String.duplicate("Hello #{name}! ", count)
    end

    # Unsigned function — should not be affected by use Inspex.Signature
    def unsigned(x), do: x * 2
  end

  describe "basic args and ret" do
    test "valid call passes through unchanged" do
      assert BasicSubject.greet("Mark", 2) == "Hello Mark! Hello Mark! "
    end

    test "invalid arg raises SignatureError with :args kind" do
      assert_raise Inspex.SignatureError, fn ->
        BasicSubject.greet("", 2)   # empty string fails string(:filled?)
      end
    end

    test "error reports the correct argument index via error path" do
      try do
        BasicSubject.greet("Mark", -1)   # -1 fails integer(gte?: 0)
      rescue
        e in Inspex.SignatureError ->
          assert e.kind == :args
          assert e.function == :greet
          assert e.arity == 2
          # Path starts with {:arg, 1} — the second argument
          assert Enum.any?(e.errors, fn err ->
            match?([{:arg, 1} | _], err.path)
          end)
      end
    end

    test "wrong type for first arg — path is {:arg, 0}" do
      try do
        BasicSubject.greet(42, 1)
      rescue
        e in Inspex.SignatureError ->
          assert e.kind == :args
          assert Enum.any?(e.errors, fn err ->
            match?([{:arg, 0} | _], err.path)
          end)
      end
    end

    test "errors from multiple failing args are accumulated" do
      try do
        BasicSubject.greet(42, -1)   # arg[0] wrong type, arg[1] fails gte?: 0
      rescue
        e in Inspex.SignatureError ->
          assert e.kind == :args
          indices =
            e.errors
            |> Enum.map(fn %{path: [{:arg, idx} | _]} -> idx end)
            |> Enum.uniq()
          assert 0 in indices
          assert 1 in indices
      end
    end

    test "invalid return value raises SignatureError with :ret kind" do
      # greet/2 returns "" when count is 0 (empty string fails :filled? on ret)
      assert_raise Inspex.SignatureError, fn ->
        BasicSubject.greet("Mark", 0)
      end
    end

    test "ret error path starts with :ret" do
      try do
        BasicSubject.greet("Mark", 0)
      rescue
        e in Inspex.SignatureError ->
          assert e.kind == :ret
          assert e.function == :greet
          assert Enum.any?(e.errors, fn err ->
            match?([:ret | _], err.path)
          end)
      end
    end

    test "unsigned functions are unaffected" do
      assert BasicSubject.unsigned(21) == 42
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-clause function
  # ---------------------------------------------------------------------------
  defmodule MultiClause do
    use Inspex.Signature

    signature args: [integer()], ret: integer()
    def fact(0), do: 1
    def fact(n) when n > 0, do: n * fact(n - 1)
  end

  describe "multi-clause function" do
    test "first clause (base case) works" do
      assert MultiClause.fact(0) == 1
    end

    test "recursive clause works" do
      assert MultiClause.fact(5) == 120
    end

    test "arg violation raises SignatureError" do
      assert_raise Inspex.SignatureError, fn ->
        MultiClause.fact("not an integer")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Zero-arity function (ret only)
  # ---------------------------------------------------------------------------
  defmodule ZeroArity do
    use Inspex.Signature

    signature ret: string(:filled?)
    def config_key, do: "my_key"

    signature ret: string(:filled?)
    def bad_key, do: ""
  end

  describe "zero-arity function" do
    test "valid return passes through" do
      assert ZeroArity.config_key() == "my_key"
    end

    test "invalid return raises SignatureError" do
      assert_raise Inspex.SignatureError, fn ->
        ZeroArity.bad_key()
      end
    end
  end

  # ---------------------------------------------------------------------------
  # :fn relationship constraint
  # ---------------------------------------------------------------------------
  defmodule WithFnConstraint do
    use Inspex.Signature

    signature args: [integer(), integer()],
              ret:  integer(),
              fn:   spec(fn {[a, _b], ret} -> ret >= a end)
    def add(a, b), do: a + b
  end

  describe ":fn relationship constraint" do
    test "valid relationship passes through" do
      assert WithFnConstraint.add(3, 4) == 7
    end

    test ":fn violation raises SignatureError with :fn kind" do
      defmodule FnViolator do
        use Inspex.Signature

        signature args: [integer()],
                  ret:  integer(),
                  fn:   spec(fn {[a], ret} -> ret == a end)
        def identity(_n), do: 99
      end

      assert_raise Inspex.SignatureError, fn ->
        FnViolator.identity(1)
      end

      try do
        FnViolator.identity(1)
      rescue
        e in Inspex.SignatureError -> assert e.kind == :fn
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ref/1 in signature specs (registry integration)
  # ---------------------------------------------------------------------------
  defmodule WithRef do
    use Inspex.Signature

    signature args: [ref(:sig_test_email)],
              ret:  boolean()
    def valid_email?(email), do: String.contains?(email, "@")
  end

  describe "ref/1 in signature" do
    setup do
      Inspex.Registry.register_local(:sig_test_email, Inspex.string(:filled?, format: ~r/@/))
      on_exit(&Inspex.Registry.clear_local/0)
    end

    test "valid email passes args check" do
      assert WithRef.valid_email?("user@example.com") == true
    end

    test "invalid arg raises SignatureError" do
      assert_raise Inspex.SignatureError, fn ->
        WithRef.valid_email?("notanemail")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Coercion in signature specs
  # ---------------------------------------------------------------------------
  defmodule WithCoercion do
    use Inspex.Signature

    signature args: [coerce(integer(gte?: 0), from: :string)],
              ret:  string(:filled?)
    def times_two(n), do: Integer.to_string(n * 2)
  end

  describe "coercion in signature args" do
    test "string arg is coerced to integer before the impl is called" do
      # Coercion converts "5" → 5; the impl receives 5, not "5"
      assert WithCoercion.times_two("5") == "10"
    end

    test "integer arg passes directly (idempotent coercion)" do
      assert WithCoercion.times_two(5) == "10"
    end

    test "invalid string raises SignatureError" do
      assert_raise Inspex.SignatureError, fn ->
        WithCoercion.times_two("bad")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # SignatureError message formatting
  # ---------------------------------------------------------------------------
  describe "SignatureError message" do
    test ":args error message includes argument path" do
      try do
        BasicSubject.greet(42, 1)
      rescue
        e in Inspex.SignatureError ->
          msg = Exception.message(e)
          assert msg =~ "Inspex.SignatureTest.BasicSubject"
          assert msg =~ "greet/2"
          assert msg =~ "argument[0]"
      end
    end

    test ":ret error message includes return path" do
      try do
        BasicSubject.greet("Mark", 0)
      rescue
        e in Inspex.SignatureError ->
          msg = Exception.message(e)
          assert msg =~ "greet/2"
          assert msg =~ "return"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Path threading — schema args expose nested field paths
  # ---------------------------------------------------------------------------
  defmodule WithSchemaArg do
    use Inspex.Signature
    import Inspex

    signature args: [schema(%{
                required(:name)  => string(:filled?),
                required(:email) => string(:filled?, format: ~r/@/)
              })],
              ret: boolean()
    def validate(params), do: map_size(params) > 0
  end

  describe "path threading through schema args" do
    test "nested field paths are prefixed with {:arg, 0}" do
      try do
        WithSchemaArg.validate(%{name: "", email: "not-an-email"})
      rescue
        e in Inspex.SignatureError ->
          assert e.kind == :args
          paths = Enum.map(e.errors, & &1.path)
          assert [{:arg, 0}, :name] in paths
          assert [{:arg, 0}, :email] in paths
      end
    end

    test "error message renders nested paths as argument[0][:field]" do
      try do
        WithSchemaArg.validate(%{name: "", email: "not-an-email"})
      rescue
        e in Inspex.SignatureError ->
          msg = Exception.message(e)
          assert msg =~ "argument[0][:name]"
          assert msg =~ "argument[0][:email]"
      end
    end

    test "valid schema arg passes through" do
      assert WithSchemaArg.validate(%{name: "Mark", email: "mark@example.com"}) == true
    end
  end

  # ---------------------------------------------------------------------------
  # Signature does not affect defp or other macros
  # ---------------------------------------------------------------------------
  defmodule WithPrivate do
    use Inspex.Signature

    signature args: [integer()], ret: integer()
    def double(n), do: helper(n)

    defp helper(n), do: n * 2
  end

  describe "private functions are not affected" do
    test "private helper is not wrapped or renamed" do
      assert WithPrivate.double(5) == 10
    end
  end
end
