defmodule Gladius.SchemaIntrospectionTest do
  use ExUnit.Case, async: true

  import Gladius

  defp user_schema do
    schema(%{
      required(:name)  => string(:filled?),
      required(:email) => string(:filled?, format: ~r/@/),
      required(:age)   => integer(gte?: 0),
      optional(:role)  => atom(in?: [:admin, :user]),
      optional(:bio)   => string()
    })
  end

  # ---------------------------------------------------------------------------
  # fields/1
  # ---------------------------------------------------------------------------

  describe "Gladius.Schema.fields/1" do
    test "returns a list of field descriptors" do
      result = Gladius.Schema.fields(user_schema())
      assert is_list(result)
      assert length(result) == 5
    end

    test "each descriptor has :name, :required, and :spec keys" do
      [first | _] = Gladius.Schema.fields(user_schema())
      assert Map.has_key?(first, :name)
      assert Map.has_key?(first, :required)
      assert Map.has_key?(first, :spec)
    end

    test "contains all declared fields" do
      names = user_schema() |> Gladius.Schema.fields() |> Enum.map(& &1.name)
      assert Enum.sort(names) == Enum.sort([:name, :email, :age, :role, :bio])
    end

    test "required field has required: true" do
      name_field = user_schema() |> Gladius.Schema.fields() |> Enum.find(&(&1.name == :name))
      assert name_field.required == true
    end

    test "optional field has required: false" do
      role_field = user_schema() |> Gladius.Schema.fields() |> Enum.find(&(&1.name == :role))
      assert role_field.required == false
    end

    test "spec is the original spec value" do
      age_field = user_schema() |> Gladius.Schema.fields() |> Enum.find(&(&1.name == :age))
      assert age_field.spec == integer(gte?: 0)
    end

    test "spec preserves coercions" do
      s = schema(%{required(:age) => coerce(integer(), from: :string)})
      [field] = Gladius.Schema.fields(s)
      assert %Gladius.Spec{coercion: coerce_fn} = field.spec
      assert is_function(coerce_fn, 1)
    end

    test "spec preserves transforms" do
      s = schema(%{required(:name) => transform(string(:filled?), &String.trim/1)})
      [field] = Gladius.Schema.fields(s)
      assert %Gladius.Transform{} = field.spec
    end

    test "spec preserves defaults" do
      s = schema(%{optional(:role) => default(atom(in?: [:admin, :user]), :user)})
      [field] = Gladius.Schema.fields(s)
      assert %Gladius.Default{value: :user} = field.spec
    end

    test "spec preserves custom messages" do
      s = schema(%{required(:name) => string(:filled?, message: "can't be blank")})
      [field] = Gladius.Schema.fields(s)
      assert field.spec.message == "can't be blank"
    end

    test "works on open_schema" do
      s = open_schema(%{required(:id) => integer()})
      [field] = Gladius.Schema.fields(s)
      assert field.name == :id
    end

    test "raises ArgumentError for non-schema conformable" do
      assert_raise ArgumentError, fn ->
        Gladius.Schema.fields(integer())
      end
    end

    test "raises ArgumentError for a plain spec" do
      assert_raise ArgumentError, fn ->
        Gladius.Schema.fields(string(:filled?))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Wrapper transparency
  # ---------------------------------------------------------------------------

  describe "wrapper transparency" do
    test "unwraps validate/2" do
      s = schema(%{required(:x) => integer()}) |> validate(fn _ -> :ok end)
      fields = Gladius.Schema.fields(s)
      assert length(fields) == 1
      assert hd(fields).name == :x
    end

    test "unwraps default/2 wrapping a schema" do
      inner = schema(%{required(:x) => integer()})
      wrapped = default(inner, %{x: 0})
      fields = Gladius.Schema.fields(wrapped)
      assert length(fields) == 1
      assert hd(fields).name == :x
    end

    test "unwraps transform/2 wrapping a schema" do
      inner = schema(%{required(:x) => integer()})
      wrapped = transform(inner, & &1)
      fields = Gladius.Schema.fields(wrapped)
      assert length(fields) == 1
    end

    test "unwraps maybe/1 wrapping a schema" do
      inner = schema(%{required(:x) => integer()})
      wrapped = maybe(inner)
      fields = Gladius.Schema.fields(wrapped)
      assert length(fields) == 1
    end

    test "unwraps ref pointing to a schema" do
      Gladius.Registry.register(:introspection_test_schema,
        schema(%{required(:x) => integer(), optional(:y) => string()}))
      fields = Gladius.Schema.fields(ref(:introspection_test_schema))
      assert length(fields) == 2
      assert Enum.sort(Enum.map(fields, & &1.name)) == Enum.sort([:x, :y])
    end

    test "unwraps extend/2 result (which is a plain %Schema{})" do
      base = schema(%{required(:name) => string(:filled?)})
      extended = extend(base, %{optional(:role) => atom()})
      fields = Gladius.Schema.fields(extended)
      assert length(fields) == 2
      assert Enum.map(fields, & &1.name) == [:name, :role]
    end
  end

  # ---------------------------------------------------------------------------
  # required_fields/1 and optional_fields/1
  # ---------------------------------------------------------------------------

  describe "required_fields/1" do
    test "returns only required fields" do
      result = Gladius.Schema.required_fields(user_schema())
      assert length(result) == 3
      assert Enum.all?(result, & &1.required)
    end

    test "names are correct" do
      names = user_schema() |> Gladius.Schema.required_fields() |> Enum.map(& &1.name)
      assert Enum.sort(names) == Enum.sort([:name, :email, :age])
    end

    test "empty list when no required fields" do
      s = schema(%{optional(:x) => integer(), optional(:y) => string()})
      assert Gladius.Schema.required_fields(s) == []
    end
  end

  describe "optional_fields/1" do
    test "returns only optional fields" do
      result = Gladius.Schema.optional_fields(user_schema())
      assert length(result) == 2
      assert Enum.all?(result, &(not &1.required))
    end

    test "names are correct" do
      names = user_schema() |> Gladius.Schema.optional_fields() |> Enum.map(& &1.name)
      assert Enum.sort(names) == [:bio, :role]
    end

    test "empty list when no optional fields" do
      s = schema(%{required(:x) => integer()})
      assert Gladius.Schema.optional_fields(s) == []
    end
  end

  # ---------------------------------------------------------------------------
  # field_names/1
  # ---------------------------------------------------------------------------

  describe "field_names/1" do
    test "returns all field names" do
      names = Gladius.Schema.field_names(user_schema())
      assert Enum.sort(names) == Enum.sort([:name, :email, :age, :role, :bio])
    end

    test "works on extend/2 result" do
      base = schema(%{required(:a) => integer(), required(:b) => string()})
      extended = extend(base, %{optional(:c) => boolean()})
      names = Gladius.Schema.field_names(extended)
      assert Enum.sort(names) == [:a, :b, :c]
    end

    test "works on selection/2 result" do
      s = selection(user_schema(), [:name, :age])
      names = Gladius.Schema.field_names(s)
      assert Enum.sort(names) == [:age, :name]
    end

    test "empty list for empty schema" do
      assert Gladius.Schema.field_names(schema(%{})) == []
    end
  end

  # ---------------------------------------------------------------------------
  # schema?/1
  # ---------------------------------------------------------------------------

  describe "schema?/1" do
    test "true for schema/1 result" do
      assert Gladius.Schema.schema?(schema(%{required(:x) => integer()}))
    end

    test "true for open_schema/1 result" do
      assert Gladius.Schema.schema?(open_schema(%{required(:x) => integer()}))
    end

    test "true for validate/2 wrapping a schema" do
      s = schema(%{required(:x) => integer()}) |> validate(fn _ -> :ok end)
      assert Gladius.Schema.schema?(s)
    end

    test "false for a primitive spec" do
      refute Gladius.Schema.schema?(integer())
    end

    test "false for list_of" do
      refute Gladius.Schema.schema?(list_of(integer()))
    end

    test "false for nil_spec" do
      refute Gladius.Schema.schema?(nil_spec())
    end
  end

  # ---------------------------------------------------------------------------
  # open?/1
  # ---------------------------------------------------------------------------

  describe "open?/1" do
    test "false for closed schema" do
      refute Gladius.Schema.open?(schema(%{required(:x) => integer()}))
    end

    test "true for open_schema" do
      assert Gladius.Schema.open?(open_schema(%{required(:x) => integer()}))
    end

    test "false for non-schema conformable" do
      refute Gladius.Schema.open?(integer())
    end

    test "inherited by extend/2" do
      open_base  = open_schema(%{required(:x) => integer()})
      closed_base = schema(%{required(:x) => integer()})

      assert Gladius.Schema.open?(extend(open_base, %{}))
      refute Gladius.Schema.open?(extend(closed_base, %{}))
    end

    test "overridden by extend/3 open: option" do
      closed = schema(%{required(:x) => integer()})
      assert Gladius.Schema.open?(extend(closed, %{}, open?: true))
    end
  end

  # ---------------------------------------------------------------------------
  # Practical use cases
  # ---------------------------------------------------------------------------

  describe "practical use cases" do
    test "build a types map for Ecto.Changeset.cast manually" do
      s = schema(%{
        required(:name) => string(),
        required(:age)  => integer(),
        optional(:active) => boolean()
      })

      type_map =
        s
        |> Gladius.Schema.fields()
        |> Map.new(fn %{name: name, spec: spec} ->
          ecto_type =
            case spec do
              %Gladius.Spec{type: :string}  -> :string
              %Gladius.Spec{type: :integer} -> :integer
              %Gladius.Spec{type: :boolean} -> :boolean
              _                             -> :any
            end
          {name, ecto_type}
        end)

      assert type_map == %{name: :string, age: :integer, active: :boolean}
    end

    test "check if all required fields are present in a map" do
      required_names = user_schema() |> Gladius.Schema.required_fields() |> Enum.map(& &1.name)
      input = %{name: "Mark", email: "m@x.com", age: 33}
      assert Enum.all?(required_names, &Map.has_key?(input, &1))
    end

    test "enumerate nested schema fields" do
      address_schema = schema(%{
        required(:street) => string(:filled?),
        required(:zip)    => string(size?: 5)
      })

      outer = schema(%{
        required(:name)    => string(:filled?),
        required(:address) => address_schema
      })

      outer_names = Gladius.Schema.field_names(outer)
      assert :name    in outer_names
      assert :address in outer_names

      address_field = outer |> Gladius.Schema.fields() |> Enum.find(&(&1.name == :address))
      nested_names  = Gladius.Schema.field_names(address_field.spec)
      assert Enum.sort(nested_names) == [:street, :zip]
    end
  end
end
