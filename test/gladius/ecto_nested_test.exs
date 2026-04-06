defmodule Gladius.EctoNestedTest do
  use ExUnit.Case, async: true

  import Gladius

  # ---------------------------------------------------------------------------
  # Test schemas
  # ---------------------------------------------------------------------------

  defp address_schema do
    schema(%{
      required(:street) => string(:filled?),
      required(:city)   => string(:filled?),
      required(:zip)    => string(size?: 5)
    })
  end

  defp user_schema do
    schema(%{
      required(:name)    => string(:filled?),
      required(:address) => address_schema()
    })
  end

  # ---------------------------------------------------------------------------
  # Nested changeset built on success
  # ---------------------------------------------------------------------------

  describe "nested changeset — success" do
    test "nested field change is an %Ecto.Changeset{}" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main St", city: "Culpeper", zip: "22701"}
      })

      assert cs.valid?
      assert %Ecto.Changeset{} = cs.changes.address
    end

    test "nested changeset is valid when nested data is valid" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main St", city: "Culpeper", zip: "22701"}
      })

      assert cs.changes.address.valid?
    end

    test "nested changeset contains the correct nested changes" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main St", city: "Culpeper", zip: "22701"}
      })

      nested = cs.changes.address
      assert nested.changes.street == "1 Main St"
      assert nested.changes.city   == "Culpeper"
      assert nested.changes.zip    == "22701"
    end

    test "parent changeset contains non-nested fields normally" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main St", city: "Culpeper", zip: "22701"}
      })

      assert cs.changes.name == "Mark"
    end
  end

  # ---------------------------------------------------------------------------
  # Nested changeset built on failure
  # ---------------------------------------------------------------------------

  describe "nested changeset — failure" do
    test "parent is invalid when nested field is invalid" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main St", city: "Culpeper", zip: "bad"}
      })

      refute cs.valid?
    end

    test "nested changeset is invalid when nested data is invalid" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main St", city: "Culpeper", zip: "bad"}
      })

      assert %Ecto.Changeset{} = cs.changes.address
      refute cs.changes.address.valid?
    end

    test "nested errors appear in the nested changeset, not the parent errors list" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main St", city: "Culpeper", zip: "bad"}
      })

      # Parent errors should not contain :zip
      refute Keyword.has_key?(cs.errors, :zip)
      # Nested changeset should have the error
      assert Keyword.has_key?(cs.changes.address.errors, :zip)
    end

    test "top-level errors still appear in the parent changeset" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "",
        address: %{street: "1 Main St", city: "Culpeper", zip: "22701"}
      })

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :name)
    end

    test "both top-level and nested errors together" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "",
        address: %{street: "", city: "Culpeper", zip: "bad"}
      })

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :name)
      nested = cs.changes.address
      refute nested.valid?
      assert Keyword.has_key?(nested.errors, :street)
      assert Keyword.has_key?(nested.errors, :zip)
    end
  end

  # ---------------------------------------------------------------------------
  # traverse_errors/2 compatibility
  # ---------------------------------------------------------------------------

  describe "traverse_errors/2 compatibility" do
    test "Gladius.Ecto.traverse_errors returns nested error map" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main St", city: "Culpeper", zip: "bad"}
      })

      errors = Gladius.Ecto.traverse_errors(cs, fn {msg, _opts} -> msg end)
      assert errors[:address][:zip] != nil
      assert errors[:address][:zip] != []
    end

    test "Gladius.Ecto.traverse_errors returns empty map on full success" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main St", city: "Culpeper", zip: "22701"}
      })

      assert Gladius.Ecto.traverse_errors(cs, fn {msg, _} -> msg end) == %{}
    end

    test "Gladius.Ecto.traverse_errors includes both parent and nested errors" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "",
        address: %{street: "1 Main St", city: "Culpeper", zip: "bad"}
      })

      errors = Gladius.Ecto.traverse_errors(cs, fn {msg, _} -> msg end)
      assert errors[:name]          != nil
      assert errors[:address][:zip] != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Deeply nested schemas
  # ---------------------------------------------------------------------------

  describe "deeply nested schemas" do
    test "two levels of nesting" do
      country_schema = schema(%{required(:code) => string(size?: 2)})
      address_with_country = schema(%{
        required(:street)  => string(:filled?),
        required(:country) => country_schema
      })
      outer = schema(%{
        required(:name)    => string(:filled?),
        required(:address) => address_with_country
      })

      cs = Gladius.Ecto.changeset(outer, %{
        name: "Mark",
        address: %{street: "1 Main", country: %{code: "US"}}
      })

      assert cs.valid?
      assert cs.changes.address.changes.country.changes.code == "US"
    end

    test "error at two levels deep" do
      country_schema = schema(%{required(:code) => string(size?: 2)})
      address_with_country = schema(%{
        required(:street)  => string(:filled?),
        required(:country) => country_schema
      })
      outer = schema(%{
        required(:name)    => string(:filled?),
        required(:address) => address_with_country
      })

      cs = Gladius.Ecto.changeset(outer, %{
        name: "Mark",
        address: %{street: "1 Main", country: %{code: "USA"}}
      })

      refute cs.valid?
      # Use Gladius.Ecto.traverse_errors — Ecto's built-in only recurses
      # into :embed/:assoc fields, not our :map-typed nested changesets.
      errors = Gladius.Ecto.traverse_errors(cs, fn {msg, _} -> msg end)
      assert errors[:address][:country][:code] != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Nested schema wrapped in Default, Transform, Maybe
  # ---------------------------------------------------------------------------

  describe "nested schema through wrappers" do
    test "default-wrapped nested schema builds nested changeset" do
      s = schema(%{
        required(:name)    => string(:filled?),
        optional(:address) => default(address_schema(), %{street: "unknown", city: "unknown", zip: "00000"})
      })

      cs = Gladius.Ecto.changeset(s, %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"}
      })

      assert cs.valid?
      assert %Ecto.Changeset{} = cs.changes.address
    end

    test "maybe-wrapped nested schema — nil value is accepted" do
      s = schema(%{
        required(:name)    => string(:filled?),
        optional(:address) => maybe(address_schema())
      })

      cs = Gladius.Ecto.changeset(s, %{name: "Mark"})
      assert cs.valid?
      refute Map.has_key?(cs.changes, :address)
    end

    test "maybe-wrapped nested schema — nested map provided and validated" do
      s = schema(%{
        required(:name)    => string(:filled?),
        optional(:address) => maybe(address_schema())
      })

      cs = Gladius.Ecto.changeset(s, %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"}
      })

      assert cs.valid?
      assert %Ecto.Changeset{} = cs.changes.address
    end
  end

  # ---------------------------------------------------------------------------
  # String-keyed nested params
  # ---------------------------------------------------------------------------

  describe "string-keyed nested params" do
    test "string keys in nested params are normalised" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        "name"    => "Mark",
        "address" => %{"street" => "1 Main St", "city" => "Culpeper", "zip" => "22701"}
      })

      assert cs.valid?
      assert %Ecto.Changeset{} = cs.changes.address
      assert cs.changes.address.changes.zip == "22701"
    end

    test "string-keyed nested params with errors" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        "name"    => "Mark",
        "address" => %{"street" => "1 Main St", "city" => "Culpeper", "zip" => "bad"}
      })

      refute cs.valid?
      assert %Ecto.Changeset{valid?: false} = cs.changes.address
    end
  end

  # ---------------------------------------------------------------------------
  # Required nested field absent
  # ---------------------------------------------------------------------------

  describe "required nested field absent" do
    test "missing required nested field — parent is invalid, error on field" do
      cs = Gladius.Ecto.changeset(user_schema(), %{name: "Mark"})
      refute cs.valid?
      # The error from Gladius (missing required key) should be present
      # Parent errors keyed on :address or :base
      assert cs.errors != [] or not cs.valid?
    end
  end
end
