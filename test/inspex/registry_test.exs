defmodule Inspex.RegistryTest do
  # async: false because some tests exercise the shared ETS table directly.
  # Tests that only use register_local can remain isolated, but the global
  # register/clear tests share state.
  use ExUnit.Case, async: false

  import Inspex

  setup do
    Inspex.Registry.clear()
    Inspex.Registry.clear_local()
    on_exit(fn ->
      Inspex.Registry.clear()
      Inspex.Registry.clear_local()
    end)
  end

  # ===========================================================================
  # Global registration (ETS)
  # ===========================================================================

  describe "global registration" do
    test "register/2 and fetch!/1 roundtrip" do
      Inspex.Registry.register(:test_spec, integer(gt?: 0))
      fetched = Inspex.Registry.fetch!(:test_spec)
      assert {:ok, 5} = conform(fetched, 5)
    end

    test "overwrites previous registration" do
      Inspex.Registry.register(:overwrite, integer())
      Inspex.Registry.register(:overwrite, string())
      fetched = Inspex.Registry.fetch!(:overwrite)
      assert {:ok, "hi"} = conform(fetched, "hi")
      assert {:error, _} = conform(fetched, 42)
    end

    test "unregister/1 removes the entry" do
      Inspex.Registry.register(:gone, integer())
      Inspex.Registry.unregister(:gone)
      assert_raise Inspex.UndefinedSpecError, fn ->
        Inspex.Registry.fetch!(:gone)
      end
    end

    test "registered?/1 returns true for known names" do
      Inspex.Registry.register(:exists, string())
      assert Inspex.Registry.registered?(:exists)
      refute Inspex.Registry.registered?(:doesnt_exist)
    end

    test "all/0 returns a map of all registered specs" do
      Inspex.Registry.register(:a, integer())
      Inspex.Registry.register(:b, string())
      result = Inspex.Registry.all()
      assert Map.has_key?(result, :a)
      assert Map.has_key?(result, :b)
    end

    test "clear/0 removes all entries" do
      Inspex.Registry.register(:x, integer())
      Inspex.Registry.register(:y, string())
      Inspex.Registry.clear()
      assert Inspex.Registry.all() == %{}
    end

    test "UndefinedSpecError has a helpful message" do
      error = %Inspex.UndefinedSpecError{name: :my_missing_spec}
      msg = Exception.message(error)
      assert msg =~ "my_missing_spec"
      assert msg =~ "Inspex.def"
      assert msg =~ "register_local"
    end
  end

  # ===========================================================================
  # Local registration (process dictionary)
  # ===========================================================================

  describe "local registration" do
    test "register_local/2 is invisible to other processes" do
      Inspex.Registry.register_local(:local_only, integer())

      # Another process cannot see it
      result = Task.async(fn ->
        Inspex.Registry.registered?(:local_only)
      end) |> Task.await()

      refute result
    end

    test "local shadows global" do
      Inspex.Registry.register(:shadowed, integer())
      Inspex.Registry.register_local(:shadowed, string())

      fetched = Inspex.Registry.fetch!(:shadowed)
      assert {:ok, "hi"} = conform(fetched, "hi")
      assert {:error, _} = conform(fetched, 42)
    end

    test "after clear_local, global is visible again" do
      Inspex.Registry.register(:falls_back, integer())
      Inspex.Registry.register_local(:falls_back, string())

      Inspex.Registry.clear_local()

      fetched = Inspex.Registry.fetch!(:falls_back)
      assert {:ok, 5}    = conform(fetched, 5)
      assert {:error, _} = conform(fetched, "hi")
    end

    test "unregister_local/1 removes only the local entry" do
      Inspex.Registry.register(:partial, integer())
      Inspex.Registry.register_local(:partial, string())

      Inspex.Registry.unregister_local(:partial)

      # Falls back to global integer()
      fetched = Inspex.Registry.fetch!(:partial)
      assert {:ok, 5}    = conform(fetched, 5)
      assert {:error, _} = conform(fetched, "str")
    end

    test "registered?/1 includes local registrations" do
      Inspex.Registry.register_local(:local_check, integer())
      assert Inspex.Registry.registered?(:local_check)
    end
  end

  # ===========================================================================
  # Inspex.def/2 macro
  # ===========================================================================

  describe "defspec macro" do
    test "registers globally at call time" do
      defspec :macro_email, string(:filled?, format: ~r/@/)

      assert Inspex.Registry.registered?(:macro_email)
      fetched = Inspex.Registry.fetch!(:macro_email)
      assert {:ok, "a@b.com"} = conform(fetched, "a@b.com")
      assert {:error, _}      = conform(fetched, "notanemail")
    end

    test "ref/1 resolves a defspec-registered spec" do
      defspec :def_age, integer(gte?: 0, lte?: 150)

      user = schema(%{required(:age) => ref(:def_age)})
      assert {:ok, _}    = conform(user, %{age: 33})
      assert {:error, _} = conform(user, %{age: 200})
    end
  end

  # ===========================================================================
  # defschema macro
  # ===========================================================================

  describe "defschema" do
    # Define schemas inline in the test module for testing purposes.
    # In production code these live in dedicated schema modules.

    defschema :product do
      schema(%{
        required(:name)  => string(:filled?),
        required(:price) => float(gt?: 0.0),
        optional(:sku)   => string(min_length: 3, max_length: 20)
      })
    end

    test "generates name/1 that returns {:ok, value}" do
      assert {:ok, result} = product(%{name: "Widget", price: 9.99})
      assert result.name == "Widget"
      assert result.price == 9.99
    end

    test "generates name/1 that returns {:error, errors}" do
      assert {:error, errors} = product(%{name: "", price: -1.0})
      paths = Enum.map(errors, & &1.path)
      assert [:name] in paths
      assert [:price] in paths
    end

    test "generates name!/1 that returns the shaped value on success" do
      assert %{name: "Widget"} = product!(%{name: "Widget", price: 9.99})
    end

    test "generates name!/1 that raises ConformError on failure" do
      assert_raise Inspex.ConformError, fn ->
        product!(%{name: "", price: -1.0})
      end
    end

    test "ConformError message includes the schema name and errors" do
      try do
        product!(%{name: ""})
      rescue
        e in Inspex.ConformError ->
          msg = Exception.message(e)
          assert msg =~ "product"
          assert msg =~ ":name"
      end
    end

    test "optional fields are absent from the output when not provided" do
      assert {:ok, result} = product(%{name: "Widget", price: 9.99})
      refute Map.has_key?(result, :sku)
    end

    test "optional fields are present when provided" do
      assert {:ok, result} = product(%{name: "Widget", price: 9.99, sku: "WDG-001"})
      assert result.sku == "WDG-001"
    end

    defschema :point do
      schema(%{
        required(:x) => number(),
        required(:y) => number()
      })
    end

    test "multiple defschemas in the same module work independently" do
      assert {:ok, _} = point(%{x: 1, y: 2})
      assert {:ok, _} = product(%{name: "A", price: 1.0})
      assert {:error, _} = point(%{x: "not_a_number", y: 2})
    end
  end

  # ===========================================================================
  # ref/1 integration with the full ETS registry
  # ===========================================================================

  describe "ref/1 — global ETS resolution" do
    test "resolves at conform-time, not schema-build-time" do
      # Build the schema BEFORE registering the spec it references.
      # If ref resolved at build-time, this would fail immediately.
      user = schema(%{
        required(:name)  => string(:filled?),
        required(:level) => ref(:level)
      })

      # Register AFTER schema construction — this is the key test
      Inspex.Registry.register(:level, integer(gte?: 1, lte?: 100))

      assert {:ok, _}    = conform(user, %{name: "Mark", level: 42})
      assert {:error, _} = conform(user, %{name: "Mark", level: 0})
    end

    test "circular schema via ref (tree structure)" do
      # A tree node: value + optional children (list of tree nodes)
      Inspex.Registry.register(:tree_node, schema(%{
        required(:value)    => integer(),
        optional(:children) => maybe(list_of(ref(:tree_node)))
      }))

      tree = %{
        value: 1,
        children: [
          %{value: 2, children: nil},
          %{value: 3, children: [%{value: 4}]}
        ]
      }

      assert {:ok, _} = conform(ref(:tree_node), tree)
    end

    test "ref resolves the latest registration (late binding)" do
      Inspex.Registry.register(:mutable, integer())
      spec = ref(:mutable)

      assert {:ok, 5}    = conform(spec, 5)
      assert {:error, _} = conform(spec, "hi")

      # Re-register with a different spec
      Inspex.Registry.register(:mutable, string())

      # The SAME ref struct now resolves differently
      assert {:ok, "hi"} = conform(spec, "hi")
      assert {:error, _} = conform(spec, 5)
    end
  end
end
