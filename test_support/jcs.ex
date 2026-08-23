defmodule Jcs do
  @moduledoc """
  RFC 8785 (JSON Canonicalization Scheme) serialization, **for tests only**.

  Specification section 20: "the conformance suite SHOULD serialize checkpoints
  and views using RFC 8785 canonical JSON when comparing runtimes or runs."
  That is what this module is for. It is compiled only into the test path of
  both projects (`test_support/` is on `elixirc_paths(:test)` for each), so no
  library depends on it and no runtime behaviour is defined by it.

  Input is an already-decoded JSON value: `nil`, `true`, `false`, a binary, an
  integer, a float, a list, or a map with binary keys. Output is the canonical
  UTF-8 byte string -- no whitespace, no trailing newline.

  ## The two places a hand-rolled canonicalizer breaks

  **1. Number formatting.** RFC 8785 delegates to ECMAScript `Number::toString`,
  which is *not* "print the float". It selects the shortest decimal digit
  string `s` (with `k` digits) and exponent `n` such that `s x 10^(n-k)` is the
  value, and then chooses among four layouts by where `n` falls:

      k <= n <= 21     ->  digits then n-k zeros        1e20  -> 100000000000000000000
      0 < n <= 21      ->  decimal point after n digits  2e-3  -> 0.002 (via the next rule)
      -6 < n <= 0      ->  "0." then -n zeros then s     1e-6  -> 0.000001
      otherwise        ->  exponential, "e+"/"e-"        1e21  -> 1e+21, 1e-7 -> 1e-7

  The boundaries are exact and asymmetric: `1e20` expands, `1e21` does not;
  `1e-6` expands, `1e-7` does not. Elixir's own `Float.to_string/1` agrees with
  none of the four (it renders `1.0e30`, not `1e+30`), so it cannot be used.

  A float spelled as an integer is an integer: `1.0` canonicalizes to `1`, and
  `-0` to `0`.

  **2. Key ordering is over UTF-16 code units, not code points.** RFC 8785
  section 3.2.3 sorts by the UTF-16 representation of the key. For astral
  characters the two disagree: U+10000 is code point 0x10000, which is *above*
  U+E000, but its UTF-16 form is the surrogate pair 0xD800 0xDC00, which is
  *below* 0xE000. Sorting Elixir binaries directly (which is code-point order
  for valid UTF-8) puts them in the wrong order. Keys are therefore transcoded
  to UTF-16 big-endian and compared as bytes, which is exactly code-unit order.

  Both traps are covered by the inherited corpus in `conformance/canonical-json`
  (cases 001, 004, and 009 through 015 are the discriminating ones); see
  `jcs_test.exs`.
  """

  @max_safe 9_007_199_254_740_991

  @doc """
  Canonicalizes a decoded JSON value to its RFC 8785 UTF-8 bytes.

  Raises `ArgumentError` for anything that is not a JSON value: a non-binary
  map key, a tuple, a struct, a non-finite float, or an integer outside the
  IEEE-754 double range.
  """
  @spec encode!(term()) :: binary()
  def encode!(value), do: IO.iodata_to_binary(value!(value))

  # -- values ---------------------------------------------------------------

  defp value!(nil), do: "null"
  defp value!(true), do: "true"
  defp value!(false), do: "false"
  defp value!(value) when is_binary(value), do: string!(value)
  defp value!(value) when is_integer(value), do: integer!(value)
  defp value!(value) when is_float(value), do: float!(value)
  defp value!(value) when is_list(value), do: array!(value)
  defp value!(%_{} = value), do: raise(ArgumentError, "not a JSON value: #{inspect(value)}")
  defp value!(value) when is_map(value), do: object!(value)
  defp value!(value), do: raise(ArgumentError, "not a JSON value: #{inspect(value)}")

  defp array!([]), do: "[]"

  defp array!(list) do
    # Array order is data, never sorted (RFC 8785 section 3.2.3).
    ["[", Enum.map_intersperse(list, ",", &value!/1), "]"]
  end

  defp object!(map) when map_size(map) == 0, do: "{}"

  defp object!(map) do
    members =
      map
      |> Enum.map(fn
        {key, value} when is_binary(key) ->
          {sort_key(key), key, value}

        {key, _value} ->
          raise ArgumentError, "JSON object keys must be strings, got: #{inspect(key)}"
      end)
      |> Enum.sort_by(fn {sort_key, _key, _value} -> sort_key end)
      |> Enum.map_intersperse(",", fn {_sort_key, key, value} ->
        [string!(key), ":", value!(value)]
      end)

    ["{", members, "}"]
  end

  # RFC 8785 section 3.2.3: sort on the UTF-16 code units of the key. Big-endian
  # UTF-16 compared as bytes IS code-unit order, and it is the surrogate pair
  # that makes this differ from comparing the UTF-8 binaries directly.
  defp sort_key(key) do
    case :unicode.characters_to_binary(key, :utf8, {:utf16, :big}) do
      utf16 when is_binary(utf16) -> utf16
      _other -> raise ArgumentError, "JSON object key is not valid UTF-8: #{inspect(key)}"
    end
  end

  # -- strings (RFC 8785 section 3.2.2.2) -----------------------------------

  defp string!(binary) do
    ["\"", escape(binary, binary, 0, 0, []), "\""]
  end

  # Copy-on-escape: `offset`/`len` delimit the current run of characters that
  # need no escaping, emitted as one slice of the original binary rather than
  # rebuilt byte by byte.
  defp escape(<<>>, original, offset, len, acc),
    do: [acc | [binary_part(original, offset, len)]]

  for {char, escaped} <-
        [{?", "\\\""}, {?\\, "\\\\"}, {?\b, "\\b"}, {?\f, "\\f"}, {?\n, "\\n"}] ++
          [{?\r, "\\r"}, {?\t, "\\t"}] do
    defp escape(<<unquote(char), rest::binary>>, original, offset, len, acc) do
      acc = [acc, binary_part(original, offset, len), unquote(escaped)]
      escape(rest, original, offset + len + 1, 0, acc)
    end
  end

  defp escape(<<char, rest::binary>>, original, offset, len, acc) when char < 0x20 do
    hex = Base.encode16(<<char>>, case: :lower)
    acc = [acc, binary_part(original, offset, len), "\\u00", hex]
    escape(rest, original, offset + len + 1, 0, acc)
  end

  # Everything else -- including U+007F, U+0080, U+2028, U+2029 and every astral
  # character -- is emitted literally as UTF-8. RFC 8785 escapes only the two
  # mandatory characters, the six two-character forms, and C0 controls.
  defp escape(<<char::utf8, rest::binary>>, original, offset, len, acc) do
    escape(rest, original, offset, len + byte_size(<<char::utf8>>), acc)
  end

  defp escape(<<byte, _rest::binary>>, original, _offset, _len, _acc) do
    raise ArgumentError,
          "string is not valid UTF-8 (byte #{byte}): #{inspect(original, limit: 40)}"
  end

  # -- numbers (RFC 8785 section 3.2.2.3, ECMAScript Number::toString) -------

  # An integer within the exactly representable range prints as itself: for
  # every such value k <= n <= 21 holds, so the ECMAScript layout below would
  # produce these same digits. Outside that range the value is not exactly a
  # double, so it goes through the double formatting that RFC 8785 mandates.
  defp integer!(value) when value >= -@max_safe and value <= @max_safe,
    do: Integer.to_string(value)

  defp integer!(value) do
    float!(1.0 * value)
  rescue
    ArithmeticError ->
      reraise ArgumentError,
              [message: "integer outside IEEE-754 double range: #{value}"],
              __STACKTRACE__
  end

  # +0.0 and -0.0 both canonicalize to "0". Erlang floats are always finite, so
  # there is no NaN or infinity case to reject here.
  defp float!(value) when value == 0.0, do: "0"
  defp float!(value) when value < 0.0, do: ["-", ecmascript(-value)]
  defp float!(value), do: ecmascript(value)

  # `s` (as `digits`, k digits, no leading or trailing zero) and `n` such that
  # digits x 10^(n-k) is the value, with k minimal: exactly the (s, k, n) of the
  # ECMAScript algorithm. :short gives the shortest round-tripping decimal.
  defp ecmascript(value) do
    {digits, n} = value |> :erlang.float_to_binary([:short]) |> decompose()
    k = byte_size(digits)

    cond do
      k <= n and n <= 21 -> [digits, String.duplicate("0", n - k)]
      0 < n and n <= 21 -> [binary_part(digits, 0, n), ".", binary_part(digits, n, k - n)]
      -6 < n and n <= 0 -> ["0.", String.duplicate("0", -n), digits]
      true -> exponential(digits, k, n)
    end
  end

  defp exponential(digits, 1, n), do: [digits, exponent(n - 1)]

  defp exponential(digits, k, n) do
    [binary_part(digits, 0, 1), ".", binary_part(digits, 1, k - 1), exponent(n - 1)]
  end

  defp exponent(e) when e >= 0, do: ["e+", Integer.to_string(e)]
  defp exponent(e), do: ["e-", Integer.to_string(-e)]

  defp decompose(shortest) do
    {mantissa, exp} =
      case String.split(shortest, ["e", "E"]) do
        [mantissa] -> {mantissa, 0}
        [mantissa, exp] -> {mantissa, String.to_integer(exp)}
      end

    {int_part, frac_part} =
      case String.split(mantissa, ".") do
        [int_part] -> {int_part, ""}
        [int_part, frac_part] -> {int_part, frac_part}
      end

    trim(int_part <> frac_part, byte_size(int_part) + exp)
  end

  # Normalize to the minimal digit string: leading zeros move the decimal
  # point, trailing zeros do not.
  defp trim(<<?0, rest::binary>>, n), do: trim(rest, n - 1)

  defp trim(digits, n) do
    case String.trim_trailing(digits, "0") do
      "" -> {"0", 1}
      trimmed -> {trimmed, n}
    end
  end
end
