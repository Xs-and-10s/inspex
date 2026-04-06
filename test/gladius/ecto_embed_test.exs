defmodule Gladius.EctoEmbedTest do
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

  defp tag_schema do
    schema(%{
      required(:name)  => string(:filled?),
      optional(:color) => string()
    })
  end

  defp user_schema do
    schema(%{
      required(:name)      => string(:filled?),
      required(:address)   => address_schema(),
      optional(:tags)      => list_of(tag_schema())
    })
  end

  # ---------------------------------------------------------------------------
  # Type declarations — the core of inputs_for compatibility
  # ---------------------------------------------------------------------------

  describe "embed type declarations" do
    test "single nested schema field has :one embed type" do
      s = schema(%{
        required(:name)    => string(:filled?),
        required(:address) => address_schema()
      })

      cs = Gladius.Ecto.changeset(s, %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"}
      })

      assert {:parameterized, Ecto.Embedded,
              %Ecto.Embedded{cardinality: :one, field: :address}} = cs.types[:address]
    end

    test "list_of(schema) field has :many embed type" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:tags) => list_of(tag_schema())
      })

      cs = Gladius.Ecto.changeset(s, %{
        name: "Mark",
        tags: [%{name: "elixir"}, %{name: "ecto"}]
      })

      assert {:parameterized, Ecto.Embedded,
              %Ecto.Embedded{cardinality: :many, field: :tags}} = cs.types[:tags]
    end

    test "non-schema fields keep primitive types" do
      s = schema(%{
        required(:name)    => string(:filled?),
        required(:age)     => integer(gte?: 0),
        required(:address) => address_schema()
      })

      cs = Gladius.Ecto.changeset(s, %{
        name: "Mark", age: 33,
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"}
      })

      assert cs.types[:name] == :string
      assert cs.types[:age]  == :integer
    end

    test "nested schema wrapped in default has :one embed type" do
      s = schema(%{
        required(:name)    => string(:filled?),
        optional(:address) => default(address_schema(),
                                      %{street: "unknown", city: "unknown", zip: "00000"})
      })

      cs = Gladius.Ecto.changeset(s, %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"}
      })

      assert {:parameterized, Ecto.Embedded,
              %Ecto.Embedded{cardinality: :one}} = cs.types[:address]
    end

    test "nested schema wrapped in maybe has :one embed type" do
      s = schema(%{
        required(:name)    => string(:filled?),
        optional(:address) => maybe(address_schema())
      })

      cs = Gladius.Ecto.changeset(s, %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"}
      })

      assert {:parameterized, Ecto.Embedded,
              %Ecto.Embedded{cardinality: :one}} = cs.types[:address]
    end
  end

  # ---------------------------------------------------------------------------
  # Single nested embed — success path
  # ---------------------------------------------------------------------------

  describe "single nested embed — success" do
    test "valid nested data produces valid nested changeset in changes" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"}
      })

      assert cs.valid?
      assert %Ecto.Changeset{valid?: true} = cs.changes.address
    end

    test "nested changes contain shaped values" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"}
      })

      nested = cs.changes.address
      assert nested.changes.street == "1 Main"
      assert nested.changes.zip    == "22701"
    end

    test "Ecto.Changeset.traverse_errors/2 works natively with embed types" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"}
      })

      assert Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Single nested embed — failure path
  # ---------------------------------------------------------------------------

  describe "single nested embed — failure" do
    test "invalid nested data produces invalid nested changeset in changes" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "bad"}
      })

      refute cs.valid?
      assert %Ecto.Changeset{valid?: false} = cs.changes.address
    end

    test "nested errors appear in nested changeset errors" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "bad"}
      })

      assert Keyword.has_key?(cs.changes.address.errors, :zip)
    end

    test "Gladius.Ecto.traverse_errors/2 finds nested errors" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "bad"}
      })

      errors = Gladius.Ecto.traverse_errors(cs, fn {msg, _} -> msg end)
      assert errors[:address][:zip] != nil
    end

    test "parent and nested errors together via Gladius.Ecto.traverse_errors" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "",
        address: %{street: "1 Main", city: "Culpeper", zip: "bad"}
      })

      errors = Gladius.Ecto.traverse_errors(cs, fn {msg, _} -> msg end)
      assert errors[:name]          != nil
      assert errors[:address][:zip] != nil
    end
  end

  # ---------------------------------------------------------------------------
  # list_of(schema) — many embed — success path
  # ---------------------------------------------------------------------------

  describe "list_of(schema) — many embed — success" do
    test "valid list produces list of valid nested changesets" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"},
        tags:    [%{name: "elixir"}, %{name: "ecto", color: "purple"}]
      })

      assert cs.valid?
      assert is_list(cs.changes.tags)
      assert length(cs.changes.tags) == 2
      assert Enum.all?(cs.changes.tags, &(&1.valid?))
    end

    test "each element in changes is a %Ecto.Changeset{}" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"},
        tags:    [%{name: "elixir"}]
      })

      assert [%Ecto.Changeset{}] = cs.changes.tags
    end

    test "nested changes contain shaped values for each element" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"},
        tags:    [%{name: "elixir"}, %{name: "ecto"}]
      })

      [first, second] = cs.changes.tags
      assert first.changes.name  == "elixir"
      assert second.changes.name == "ecto"
    end

    test "empty list produces empty changes" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"},
        tags:    []
      })

      assert cs.valid?
      assert cs.changes.tags == []
    end

    test "Ecto.Changeset.traverse_errors empty on success" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"},
        tags:    [%{name: "elixir"}]
      })

      assert Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # list_of(schema) — many embed — failure path
  # ---------------------------------------------------------------------------

  describe "list_of(schema) — many embed — failure" do
    test "invalid element produces invalid changeset in the list" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"},
        tags:    [%{name: "elixir"}, %{name: ""}]
      })

      refute cs.valid?
      [first, second] = cs.changes.tags
      assert first.valid?
      refute second.valid?
    end

    test "invalid element errors appear in the element changeset" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"},
        tags:    [%{name: ""}]
      })

      [tag_cs] = cs.changes.tags
      assert Keyword.has_key?(tag_cs.errors, :name)
    end

    test "Gladius.Ecto.traverse_errors finds errors in list elements" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"},
        tags:    [%{name: "elixir"}, %{name: ""}]
      })

      errors = Gladius.Ecto.traverse_errors(cs, fn {msg, _} -> msg end)
      tag_errors = errors[:tags]
      assert is_list(tag_errors)
      assert Enum.any?(tag_errors, fn e -> e[:name] != nil end)
    end

    test "multiple invalid elements all reported" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"},
        tags:    [%{name: ""}, %{name: ""}]
      })

      refute cs.valid?
      assert length(cs.changes.tags) == 2
      assert Enum.all?(cs.changes.tags, &(not &1.valid?))
    end
  end

  # ---------------------------------------------------------------------------
  # String-keyed params
  # ---------------------------------------------------------------------------

  describe "string-keyed nested params" do
    test "string keys in single nested embed are normalised" do
      s = schema(%{
        required(:name)    => string(:filled?),
        required(:address) => address_schema()
      })

      cs = Gladius.Ecto.changeset(s, %{
        "name"    => "Mark",
        "address" => %{"street" => "1 Main", "city" => "Culpeper", "zip" => "22701"}
      })

      assert cs.valid?
      assert cs.changes.address.changes.zip == "22701"
    end

    test "string keys in list_of embed elements are normalised" do
      s = schema(%{
        required(:name) => string(:filled?),
        required(:tags) => list_of(tag_schema())
      })

      cs = Gladius.Ecto.changeset(s, %{
        "name" => "Mark",
        "tags" => [%{"name" => "elixir"}, %{"name" => "ecto"}]
      })

      assert cs.valid?
      [first, second] = cs.changes.tags
      assert first.changes.name  == "elixir"
      assert second.changes.name == "ecto"
    end
  end

  # ---------------------------------------------------------------------------
  # Gladius.Ecto.traverse_errors/2 — still works as convenience
  # ---------------------------------------------------------------------------

  describe "Gladius.Ecto.traverse_errors/2 still works" do
    test "works for single nested embed" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "bad"}
      })

      errors = Gladius.Ecto.traverse_errors(cs, fn {msg, _} -> msg end)
      assert errors[:address][:zip] != nil
    end

    test "works for list_of embed errors" do
      cs = Gladius.Ecto.changeset(user_schema(), %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"},
        tags:    [%{name: "elixir"}, %{name: ""}]
      })

      errors = Gladius.Ecto.traverse_errors(cs, fn {msg, _} -> msg end)
      tag_errors = errors[:tags]
      assert is_list(tag_errors)
      assert Enum.any?(tag_errors, &(&1[:name] != nil))
    end
  end

  # ---------------------------------------------------------------------------
  # Deeply nested embeds
  # ---------------------------------------------------------------------------

  describe "deeply nested embeds" do
    test "two levels: Gladius.Ecto.traverse_errors works" do
      country_schema = schema(%{required(:code) => string(size?: 2)})
      addr_with_country = schema(%{
        required(:street)  => string(:filled?),
        required(:country) => country_schema
      })
      outer = schema(%{
        required(:name)    => string(:filled?),
        required(:address) => addr_with_country
      })

      cs = Gladius.Ecto.changeset(outer, %{
        name:    "Mark",
        address: %{street: "1 Main", country: %{code: "USA"}}
      })

      refute cs.valid?
      errors = Gladius.Ecto.traverse_errors(cs, fn {msg, _} -> msg end)
      assert errors[:address][:country][:code] != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Update workflow (base struct)
  # ---------------------------------------------------------------------------

  describe "update workflow with embeds" do
    defmodule User do
      defstruct [:name, :address, :tags]
    end

    test "base struct with embed — only changed fields in changes" do
      s = schema(%{
        required(:name)    => string(:filled?),
        required(:address) => address_schema()
      })

      user = %User{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"}
      }

      cs = Gladius.Ecto.changeset(s,
             %{name: "Mark", address: %{street: "2 Oak", city: "Culpeper", zip: "22701"}},
             user)

      assert cs.valid?
      assert Map.has_key?(cs.changes, :address)
    end
  end

  # ---------------------------------------------------------------------------
  # extend/2 + embeds
  # ---------------------------------------------------------------------------

  describe "extend/2 with embed fields" do
    test "embedded field added via extend has embed type" do
      base = schema(%{required(:name) => string(:filled?)})
      s = extend(base, %{required(:address) => address_schema()})

      cs = Gladius.Ecto.changeset(s, %{
        name:    "Mark",
        address: %{street: "1 Main", city: "Culpeper", zip: "22701"}
      })

      assert {:parameterized, Ecto.Embedded,
              %Ecto.Embedded{cardinality: :one}} = cs.types[:address]
      assert cs.valid?
    end
  end
end
