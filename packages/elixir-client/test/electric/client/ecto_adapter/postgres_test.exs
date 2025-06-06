defmodule Electric.Client.EctoAdapter.PostgresTest do
  use ExUnit.Case, async: true

  alias Electric.Client.EctoAdapter
  alias Support.Money

  import Ecto.Query

  defmodule TestTable do
    use Ecto.Schema

    schema "test_table" do
      field(:ii, :integer)
      field(:ff, :float)
      field(:ss, :string)
      field(:uu, :binary_id)
      field(:nd, :naive_datetime)
      field(:ud, :utc_datetime)
      field(:dd, :date)
      field(:aa, {:array, :integer})
      field(:mm, Money)
    end
  end

  defmacrop assert_where(query, expected) do
    quote do
      assert unquote(expected) == EctoAdapter.where(unquote(query))
    end
  end

  test "bound parameter is rendered to query" do
    ii = 1234
    ff = 3.14
    ss1 = "my string"
    ss2 = "it's mine"
    uu = "247a6f62-9f05-4ac6-8314-89e77177d1e3"
    nd = ~N[2024-10-23 14:36:39]
    ud = ~U[2024-10-23 14:36:39Z]
    dd = ~D[2024-10-23]
    mm = Decimal.new("199.99")

    assert_where(where(TestTable, ii: ^ii), ~s[("ii" = 1234)])
    assert_where(where(TestTable, ff: ^ff), ~s[("ff" = 3.14::float)])
    assert_where(where(TestTable, ss: ^ss1), ~s[("ss" = 'my string')])
    assert_where(where(TestTable, ss: ^ss2), ~s[("ss" = 'it''s mine')])
    assert_where(where(TestTable, uu: ^uu), ~s[("uu" = '247a6f62-9f05-4ac6-8314-89e77177d1e3')])
    assert_where(where(TestTable, nd: ^nd), ~s[("nd" = '2024-10-23T14:36:39'::timestamp)])
    assert_where(where(TestTable, ud: ^ud), ~s[("ud" = '2024-10-23T14:36:39Z'::timestamptz)])
    assert_where(where(TestTable, dd: ^dd), ~s[("dd" = '2024-10-23'::date)])
    assert_where(where(TestTable, mm: ^mm), ~s[("mm" = 199990000)])
  end

  test "fragment" do
    ii = 5678
    mm_min = Decimal.new("123.45")
    mm_max = Decimal.new("678.90")

    assert_where(
      from(t in TestTable,
        where: fragment("? = ?", t.ii, ^ii)
      ),
      ~s[("ii" = 5678)]
    )

    assert_where(
      from(t in TestTable,
        where: fragment("? BETWEEN ? AND ?", t.ii, ^10, ^100) and fragment("? IS NOT NULL", t.ss)
      ),
      ~s[("ii" BETWEEN 10 AND 100 AND "ss" IS NOT NULL)]
    )

    assert_where(
      from(t in TestTable,
        where: fragment("? > ? AND ? < ?", t.mm, ^mm_min, t.mm, ^mm_max)
      ),
      ~s[("mm" > 123450000 AND "mm" < 678900000)]
    )
  end

  test "spliced values" do
    ii = 1234
    aa = [1, 2, 3, 4]
    ss = "my string"
    uu = ["247a6f62-9f05-4ac6-8314-89e77177d1e3", "61a8129e-6970-48e8-9dae-b26777c7d225"]
    mm = [Decimal.new("199.99"), Decimal.new("150.00")]

    assert_where(
      from(t in TestTable,
        where: t.id == ^ii and fragment("? in (?)", t.ii, splice(^aa)) and t.ss == ^ss
      ),
      ~s[((("id" = 1234) AND "ii" in (1,2,3,4)) AND ("ss" = 'my string'))]
    )

    assert_where(
      from(t in TestTable,
        where: t.id == ^ii and fragment("? in (?)", t.uu, splice(^uu)) and t.ss == ^ss
      ),
      ~s[((("id" = 1234) AND "uu" in ('247a6f62-9f05-4ac6-8314-89e77177d1e3','61a8129e-6970-48e8-9dae-b26777c7d225')) AND ("ss" = 'my string'))]
    )

    assert_where(
      from(t in TestTable,
        where: t.id == ^ii and fragment("? in (?)", t.mm, splice(^mm)) and t.ss == ^ss
      ),
      ~s[((("id" = 1234) AND "mm" in (199990000,150000000)) AND ("ss" = 'my string'))]
    )
  end
end
