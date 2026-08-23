defmodule Commonplace.AttributeMap.ValidationTest do
  use ExUnit.Case, async: true

  alias Commonplace.AttributeMap.Validation

  # Reasons are pinned as atoms (spec 33), never as message strings.
  defp reason({:error, {reason, _details}}), do: reason

  describe "attribute keys (spec 25)" do
    test "accepts an ordinary key" do
      assert :ok = Validation.validate_key("commonplace.title")
    end

    test "rejects an empty key" do
      assert :key_empty = reason(Validation.validate_key(""))
    end

    test "rejects a non-string key" do
      assert :key_not_string = reason(Validation.validate_key(:title))
      assert :key_not_string = reason(Validation.validate_key(1))
      assert :key_not_string = reason(Validation.validate_key(nil))
    end

    test "accepts a 1024-BYTE key" do
      key = String.duplicate("a", 1024)
      assert 1024 = byte_size(key)
      assert :ok = Validation.validate_key(key)
    end

    test "rejects a 1025-byte key" do
      key = String.duplicate("a", 1025)
      assert 1025 = byte_size(key)
      assert :key_too_large = reason(Validation.validate_key(key))
    end

    test "measures UTF-8 BYTES, not graphemes" do
      # 300 four-byte characters: 300 graphemes, 1200 bytes. A grapheme-counting
      # implementation accepts this; a byte-counting one rejects it.
      key = String.duplicate("\u{1F600}", 300)
      assert 300 = String.length(key)
      assert 1200 = byte_size(key)
      assert :key_too_large = reason(Validation.validate_key(key))
    end

    test "accepts a multi-byte key that fits in 1024 bytes" do
      # Positive control for the byte rule: 256 four-byte chars == 1024 bytes.
      key = String.duplicate("\u{1F600}", 256)
      assert 1024 = byte_size(key)
      assert :ok = Validation.validate_key(key)
    end

    test "rejects a key containing the null code point" do
      assert :key_contains_null = reason(Validation.validate_key("a\0b"))
      assert :key_contains_null = reason(Validation.validate_key("\0"))
    end

    test "rejects a key that is not valid UTF-8" do
      assert :key_invalid_utf8 = reason(Validation.validate_key(<<0xFF, 0xFE>>))
    end

    test "does not normalize or case fold" do
      # Two keys that NFC-normalize to the same string stay distinct, so
      # validation must accept both forms unchanged.
      assert :ok = Validation.validate_key("é")
      assert :ok = Validation.validate_key("é")
      assert "é" != "é"
    end
  end

  describe "attribute values (spec 24)" do
    test "null is a VALID value" do
      assert :ok = Validation.validate_value(nil)
    end

    test "booleans are valid" do
      assert :ok = Validation.validate_value(true)
      assert :ok = Validation.validate_value(false)
    end

    test "finite numbers are valid" do
      assert :ok = Validation.validate_value(0)
      assert :ok = Validation.validate_value(-17)
      assert :ok = Validation.validate_value(3.5)
      assert :ok = Validation.validate_value(1.0e308)
    end

    test "strings are valid" do
      assert :ok = Validation.validate_value("")
      assert :ok = Validation.validate_value("hello")
      # A value string, unlike a key, has no length limit and may contain NUL.
      assert :ok = Validation.validate_value(String.duplicate("a", 5000))
      assert :ok = Validation.validate_value("a\0b")
    end

    test "rejects a string that is not valid UTF-8" do
      assert :invalid_json_value = reason(Validation.validate_value(<<0xFF, 0xFE>>))
    end

    test "arrays are valid" do
      assert :ok = Validation.validate_value([])
      assert :ok = Validation.validate_value([1, "two", nil, true, [], %{}])
    end

    test "objects with string keys are valid" do
      assert :ok = Validation.validate_value(%{})
      assert :ok = Validation.validate_value(%{"a" => 1, "b" => nil})
    end

    test "rejects a non-string object key" do
      assert :invalid_json_value = reason(Validation.validate_value(%{a: 1}))
      assert :invalid_json_value = reason(Validation.validate_value(%{1 => "x"}))
    end

    test "rejects NaN and infinity" do
      # The BEAM cannot construct a non-finite float at all -- 1.0e308 * 10
      # raises ArithmeticError, and the external term format rejects the NaN
      # and infinity bit patterns. So non-finite numbers can only reach a
      # plugin as the atoms some JSON decoders emit for them.
      big = Enum.random([1.0e308])
      assert_raise ArithmeticError, fn -> big * 10 end

      assert :invalid_json_value = reason(Validation.validate_value(:nan))
      assert :invalid_json_value = reason(Validation.validate_value(:infinity))
      assert :invalid_json_value = reason(Validation.validate_value(:neg_infinity))
      assert :invalid_json_value = reason(Validation.validate_value(:"-infinity"))
    end

    test "rejects non-JSON terms" do
      assert :invalid_json_value = reason(Validation.validate_value(:some_atom))
      assert :invalid_json_value = reason(Validation.validate_value({1, 2}))
      assert :invalid_json_value = reason(Validation.validate_value(self()))
      assert :invalid_json_value = reason(Validation.validate_value(fn -> :x end))
    end

    test "nested structures validate recursively" do
      assert :ok =
               Validation.validate_value(%{
                 "a" => [%{"b" => [1, %{"c" => nil}]}],
                 "d" => %{"e" => %{"f" => "g"}}
               })

      assert :invalid_json_value =
               reason(Validation.validate_value(%{"a" => [%{"b" => [1, %{"c" => :bad}]}]}))

      assert :invalid_json_value =
               reason(Validation.validate_value([[[[:bad]]]]))

      assert :invalid_json_value =
               reason(Validation.validate_value(%{"a" => %{:atom_key => 1}}))
    end

    test "a nested object key is not subject to the 1024-byte attribute-key limit" do
      # Spec 25 constrains attribute keys. Keys inside a value are ordinary
      # I-JSON object keys.
      big = String.duplicate("a", 2000)
      assert :ok = Validation.validate_value(%{big => 1})
    end
  end

  describe "validate_values/1" do
    test "accepts an empty object" do
      assert :ok = Validation.validate_values(%{})
    end

    test "accepts a well-formed object" do
      assert :ok = Validation.validate_values(%{"a" => 1, "b" => nil})
    end

    test "rejects a non-object" do
      assert :values_not_object = reason(Validation.validate_values([]))
      assert :values_not_object = reason(Validation.validate_values("x"))
      assert :values_not_object = reason(Validation.validate_values(nil))
    end

    test "rejects a bad key" do
      assert :key_empty = reason(Validation.validate_values(%{"" => 1}))

      assert :key_too_large =
               reason(Validation.validate_values(%{String.duplicate("a", 1025) => 1}))
    end

    test "rejects a bad value" do
      assert :invalid_json_value = reason(Validation.validate_values(%{"a" => :bad}))
    end
  end
end
