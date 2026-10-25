defmodule CymphoWeb.FormatTest do
  use ExUnit.Case, async: true

  import CymphoWeb.Format, only: [money: 1]

  describe "money/1" do
    test "keeps the r3 shapes below a thousand" do
      assert money(Decimal.new("0")) == "$0"
      assert money(Decimal.new("300")) == "$300"
      assert money(Decimal.new("186.5")) == "$186.50"
      assert money(Decimal.new("3.675")) == "$3.68"
      assert money(Decimal.new("999")) == "$999"
    end

    test "groups the whole dollars in thousands, never the cents (B12)" do
      assert money(Decimal.new("1000")) == "$1,000"
      assert money(Decimal.new("1234.5")) == "$1,234.50"
      assert money(Decimal.new("1234567.891")) == "$1,234,567.89"
      assert money(Decimal.new("999.995")) == "$1,000"
    end
  end
end
