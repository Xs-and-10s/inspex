defmodule Gladius.EctoTest do
  use ExUnit.Case, async: true

  import Gladius


  # ---------------------------------------------------------------------------
  # Test structs
  # ---------------------------------------------------------------------------

  defmodule User do
    defstruct [:name, :email, :age, :role]
  end

  # ---------------------------------------------------------------------------
  # Happy path — valid changeset
  # ---------------------------------------------------------------------------

  describe "changeset/2 — valid input" do
    test "returns a valid changeset" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 18)
      })

      cs = Gladius.Ecto.changeset(s, %{name: "Mark", age: 33})
      assert cs.valid?
    end

    test "changes contain the shaped values" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 18)
      })

      cs = Gladius.Ecto.changeset(s, %{name: "Mark", age: 33})
      assert cs.changes == %{name: "Mark", age: 33}
    end

    test "coerced values appear in changes" do
      s = schema(%{
        required(:age)    => coerce(integer(gte?: 18), from: :string),
        required(:active) => coerce(boolean(), from: :string)
      })

      cs = Gladius.Ecto.changeset(s, %{age: "25", active: "true"})
      assert cs.valid?
      assert cs.changes.age == 25
      assert cs.changes.active == true
    end

    test "transformed values appear in changes" do
      s = schema(%{
        required(:name)  => transform(string(:filled?), &String.trim/1),
        required(:email) => transform(string(:filled?, format: ~r/@/), &String.downcase/1)
      })

      cs = Gladius.Ecto.changeset(s, %{name: "  Mark  ", email: "MARK@X.COM"})
      assert cs.valid?
      assert cs.changes.name  == "Mark"
      assert cs.changes.email == "mark@x.com"
    end

    test "default values appear in changes for absent optional keys" do
      s = schema(%{
        required(:name) => string(:filled?),
        optional(:role) => default(atom(in?: [:admin, :user]), :user)
      })

      cs = Gladius.Ecto.changeset(s, %{name: "Mark"})
      assert cs.valid?
      assert cs.changes.role == :user
    end

    test "atom fields stored as-is via :any Ecto type" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:role) => atom(in?: [:admin, :user])
      })

      cs = Gladius.Ecto.changeset(s, %{name: "Mark", role: :admin})
      assert cs.valid?
      assert cs.changes.role == :admin
    end

    test "string keys in params are accepted" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => coerce(integer(gte?: 18), from: :string)
      })

      cs = Gladius.Ecto.changeset(s, %{"name" => "Mark", "age" => "25"})
      assert cs.valid?
      assert cs.changes.name == "Mark"
      assert cs.changes.age  == 25
    end

    test "no errors on success" do
      s = schema(%{required(:name) => string(:filled?)})
      cs = Gladius.Ecto.changeset(s, %{name: "Mark"})
      assert cs.errors == []
    end
  end

  # ---------------------------------------------------------------------------
  # Happy path — update workflow with base struct
  # ---------------------------------------------------------------------------

  describe "changeset/3 — base struct (update workflow)" do
    test "returns a valid changeset with the struct as base" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 18)
      })

      user = %User{name: "Mark", age: 33}
      cs   = Gladius.Ecto.changeset(s, %{name: "Mark", age: 40}, user)
      assert cs.valid?
    end

    test "only changed fields appear in changes" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 18)
      })

      user = %User{name: "Mark", age: 33}
      cs   = Gladius.Ecto.changeset(s, %{name: "Mark", age: 40}, user)
      assert cs.changes == %{age: 40}
      refute Map.has_key?(cs.changes, :name)
    end

    test "unchanged fields are absent from changes" do
      s = schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(:filled?, format: ~r/@/)
      })

      user = %User{name: "Mark", email: "mark@x.com"}
      cs   = Gladius.Ecto.changeset(s, %{name: "Mark", email: "new@x.com"}, user)
      assert cs.changes == %{email: "new@x.com"}
    end

    test "plain map base works" do
      s  = schema(%{required(:name) => string(:filled?)})
      cs = Gladius.Ecto.changeset(s, %{name: "Mark"}, %{name: "Mark"})
      assert cs.valid?
      assert cs.changes == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Error path — invalid changeset
  # ---------------------------------------------------------------------------

  describe "changeset/2 — invalid input" do
    test "returns an invalid changeset" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 18)
      })

      cs = Gladius.Ecto.changeset(s, %{name: "", age: 15})
      refute cs.valid?
    end

    test "errors list is non-empty" do
      s  = schema(%{required(:name) => string(:filled?)})
      cs = Gladius.Ecto.changeset(s, %{name: ""})
      assert cs.errors != []
    end

    test "error is keyed on the field name" do
      s  = schema(%{required(:name) => string(:filled?)})
      cs = Gladius.Ecto.changeset(s, %{name: ""})
      assert Keyword.has_key?(cs.errors, :name)
    end

    test "error message matches Gladius error message" do
      s  = schema(%{required(:age) => integer(gte?: 18)})
      cs = Gladius.Ecto.changeset(s, %{age: 15})
      {msg, _opts} = cs.errors[:age]
      assert msg =~ "18"
    end

    test "multiple field errors all present" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 18)
      })

      cs = Gladius.Ecto.changeset(s, %{name: "", age: 15})
      assert Keyword.has_key?(cs.errors, :name)
      assert Keyword.has_key?(cs.errors, :age)
    end

    test "missing required key produces an error on that key" do
      s = schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(:filled?, format: ~r/@/)
      })

      cs = Gladius.Ecto.changeset(s, %{name: "Mark"})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :email)
    end
  end

  # ---------------------------------------------------------------------------
  # Nested path errors — last segment
  # ---------------------------------------------------------------------------

  describe "nested path errors" do
    test "nested schema errors appear in the nested changeset, not parent errors" do
      inner = schema(%{required(:zip) => string(size?: 5)})
      outer = schema(%{
        required(:name)    => string(:filled?),
        required(:address) => inner
      })

      cs = Gladius.Ecto.changeset(outer, %{name: "Mark", address: %{zip: "bad"}})
      refute cs.valid?
      # Nested errors live in the nested changeset, not the parent's errors list
      refute Keyword.has_key?(cs.errors, :zip)
      assert %Ecto.Changeset{} = cs.changes.address
      assert Keyword.has_key?(cs.changes.address.errors, :zip)
    end

    test "list_of element errors surface in parent changeset under :base" do
      s = schema(%{required(:items) => list_of(integer(gte?: 0))})
      cs = Gladius.Ecto.changeset(s, %{items: [1, -1, -2]})
      refute cs.valid?
      # list_of is not a nested schema — its element errors stay on the parent.
      # path: [:items, index] → last segment is integer → keyed as :base
      assert Keyword.has_key?(cs.errors, :base)
    end
  end

  # ---------------------------------------------------------------------------
  # Composability with Ecto validators
  # ---------------------------------------------------------------------------

  describe "composing with Ecto validators" do
    test "can pipe Ecto validators after changeset/2" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 18)
      })

      cs =
        s
        |> Gladius.Ecto.changeset(%{name: "Mark", age: 33})
        |> Ecto.Changeset.validate_inclusion(:age, 18..120)

      assert cs.valid?
    end

    test "Ecto validators can add errors on top of a valid Gladius changeset" do
      s = schema(%{
        required(:role) => atom(in?: [:admin, :user])
      })

      cs =
        s
        |> Gladius.Ecto.changeset(%{role: :admin})
        |> Ecto.Changeset.validate_inclusion(:role, [:user])

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :role)
    end

    test "Ecto validators can add errors on top of an invalid Gladius changeset" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:age)  => integer(gte?: 18)
      })

      cs =
        s
        |> Gladius.Ecto.changeset(%{name: "", age: 33})
        |> Ecto.Changeset.validate_length(:name, min: 2)

      refute cs.valid?
      assert length(cs.errors) >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Type inference
  # ---------------------------------------------------------------------------

  describe "type inference" do
    test "string fields inferred as :string" do
      s  = schema(%{required(:name) => string()})
      cs = Gladius.Ecto.changeset(s, %{name: "Mark"})
      assert cs.valid?
    end

    test "integer fields inferred as :integer" do
      s  = schema(%{required(:count) => integer()})
      cs = Gladius.Ecto.changeset(s, %{count: 5})
      assert cs.valid?
    end

    test "boolean fields inferred as :boolean" do
      s  = schema(%{required(:active) => boolean()})
      cs = Gladius.Ecto.changeset(s, %{active: true})
      assert cs.valid?
    end

    test "float fields inferred as :float" do
      s  = schema(%{required(:score) => float()})
      cs = Gladius.Ecto.changeset(s, %{score: 9.5})
      assert cs.valid?
    end

    test "default wrapping a spec inherits inner type" do
      s  = schema(%{optional(:count) => default(integer(gte?: 0), 0)})
      cs = Gladius.Ecto.changeset(s, %{})
      assert cs.valid?
      assert cs.changes.count == 0
    end

    test "transform wrapping a spec inherits inner type" do
      s  = schema(%{required(:name) => transform(string(:filled?), &String.trim/1)})
      cs = Gladius.Ecto.changeset(s, %{name: "  Mark  "})
      assert cs.valid?
      assert cs.changes.name == "Mark"
    end

    test "maybe wrapping a spec inherits inner type" do
      s  = schema(%{required(:bio) => maybe(string())})
      cs = Gladius.Ecto.changeset(s, %{bio: nil})
      assert cs.valid?
    end

    test "ref inherits resolved spec type" do
      Gladius.Registry.register(:ecto_test_age, integer(gte?: 0))
      s  = schema(%{required(:age) => ref(:ecto_test_age)})
      cs = Gladius.Ecto.changeset(s, %{age: 25})
      assert cs.valid?
    end

    test "open_schema extra keys are not in types — not tracked as changes" do
      s  = open_schema(%{required(:name) => string(:filled?)})
      cs = Gladius.Ecto.changeset(s, %{name: "Mark", extra: "ignored"})
      assert cs.valid?
      assert Map.has_key?(cs.changes, :name)
      refute Map.has_key?(cs.changes, :extra)
    end
  end
end
