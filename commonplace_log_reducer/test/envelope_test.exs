defmodule Commonplace.LogReducer.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Commonplace.LogReducer.Envelope

  @uuid "0198d83a-0a1f-7ba0-aa24-21f9130f883d"
  @uuid2 "0198d83a-0a1f-7ba0-aa24-21f9130f883e"

  defp epoch(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "commonplace.reducer.epoch",
        "version" => 1,
        "projection" => "attributes",
        "epoch_id" => @uuid,
        "parent_epoch_id" => nil,
        "reducer" => %{"id" => "commonplace.attribute-map", "version" => 1},
        "base" => %{"values" => %{}}
      },
      overrides
    )
  end

  defp operation(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "commonplace.reducer.operation",
        "version" => 1,
        "projection" => "attributes",
        "epoch_id" => @uuid,
        "operation" => %{"type" => "put", "key" => "title", "value" => "Hello"}
      },
      overrides
    )
  end

  defp assert_code(body, code) do
    assert {:error, err} = Envelope.classify(body)
    Emitted.record(err)
    assert err.code == code
    err
  end

  describe "valid_projection_name?/1 (§7)" do
    test "accepts a minimal name" do
      assert Envelope.valid_projection_name?("a")
    end

    test "rejects an empty name" do
      refute Envelope.valid_projection_name?("")
    end

    test "rejects a leading digit" do
      refute Envelope.valid_projection_name?("1x")
    end

    test "rejects uppercase" do
      refute Envelope.valid_projection_name?("Attributes")
    end

    test "rejects 129 bytes" do
      refute Envelope.valid_projection_name?("a" <> String.duplicate("b", 128))
    end

    test "accepts exactly 128 bytes" do
      name = "a" <> String.duplicate("b", 127)
      assert byte_size(name) == 128
      assert Envelope.valid_projection_name?(name)
    end

    test "counts BYTES not graphemes" do
      # 127 ASCII + one 2-byte character = 128 graphemes but 129 bytes.
      name = "a" <> String.duplicate("b", 126) <> "é"
      assert String.length(name) == 128
      assert byte_size(name) == 129
      refute Envelope.valid_projection_name?(name)
    end

    test "accepts the full punctuation set" do
      assert Envelope.valid_projection_name?("a.b_c/d-e")
    end

    test "rejects a non-binary" do
      refute Envelope.valid_projection_name?(:attributes)
    end
  end

  describe "namespace classification (§8)" do
    test "a body with no type key is unrelated" do
      body = %{"hello" => "world"}
      assert {:unrelated, ^body} = Envelope.classify(body)
    end

    test "a body whose type is outside the namespace is unrelated" do
      body = %{"type" => "app.note.created", "text" => "hi"}
      assert {:unrelated, ^body} = Envelope.classify(body)
    end

    test "a body whose type merely resembles the namespace is unrelated" do
      body = %{"type" => "commonplace.reducerish.epoch"}
      assert {:unrelated, ^body} = Envelope.classify(body)
    end

    test "an UNKNOWN commonplace.reducer.* type is an error, not ignored" do
      assert_code(%{"type" => "commonplace.reducer.snapshot"}, :invalid_reducer_envelope)
    end

    test "the bare namespace prefix is an error, not ignored" do
      assert_code(%{"type" => "commonplace.reducer."}, :invalid_reducer_envelope)
    end

    test "a non-object body is an error" do
      assert_code("not an object", :invalid_reducer_envelope)
      assert_code([1, 2, 3], :invalid_reducer_envelope)
      assert_code(nil, :invalid_reducer_envelope)
    end
  end

  describe "epoch envelope (§9)" do
    test "a well-formed epoch body classifies as an epoch" do
      body = epoch()
      assert {:epoch, ^body} = Envelope.classify(body)
    end

    test "a non-null parent_epoch_id is accepted" do
      body = epoch(%{"parent_epoch_id" => @uuid2})
      assert {:epoch, ^body} = Envelope.classify(body)
    end

    test "an EXTRA field is invalid" do
      assert_code(epoch(%{"extra" => 1}), :invalid_reducer_envelope)
    end

    test "a MISSING parent_epoch_id is invalid (absent != null)" do
      assert_code(epoch() |> Map.delete("parent_epoch_id"), :invalid_reducer_envelope)
    end

    test "other missing required fields are invalid" do
      for key <- ["version", "projection", "epoch_id", "reducer", "base"] do
        assert_code(epoch() |> Map.delete(key), :invalid_reducer_envelope)
      end
    end

    test "version must be integer 1" do
      assert_code(epoch(%{"version" => 2}), :invalid_reducer_envelope)
      assert_code(epoch(%{"version" => "1"}), :invalid_reducer_envelope)
      assert_code(epoch(%{"version" => 1.0}), :invalid_reducer_envelope)
    end

    test "epoch_id must be a lowercase canonical UUID" do
      assert_code(epoch(%{"epoch_id" => String.upcase(@uuid)}), :invalid_reducer_envelope)
      assert_code(epoch(%{"epoch_id" => "not-a-uuid"}), :invalid_reducer_envelope)
      assert_code(epoch(%{"epoch_id" => nil}), :invalid_reducer_envelope)
    end

    test "parent_epoch_id, when not null, must be a lowercase canonical UUID" do
      assert_code(epoch(%{"parent_epoch_id" => String.upcase(@uuid2)}), :invalid_reducer_envelope)
      assert_code(epoch(%{"parent_epoch_id" => "nope"}), :invalid_reducer_envelope)
    end

    test "reducer must contain exactly id and version" do
      assert_code(epoch(%{"reducer" => %{"id" => "r"}}), :invalid_reducer_envelope)

      assert_code(
        epoch(%{"reducer" => %{"id" => "r", "version" => 1, "extra" => true}}),
        :invalid_reducer_envelope
      )

      assert_code(epoch(%{"reducer" => "commonplace.attribute-map"}), :invalid_reducer_envelope)
    end

    test "reducer.id must be a non-empty string" do
      assert_code(epoch(%{"reducer" => %{"id" => "", "version" => 1}}), :invalid_reducer_envelope)
      assert_code(epoch(%{"reducer" => %{"id" => 7, "version" => 1}}), :invalid_reducer_envelope)
    end

    test "reducer.version must be a positive integer" do
      assert_code(
        epoch(%{"reducer" => %{"id" => "r", "version" => 0}}),
        :invalid_reducer_envelope
      )

      assert_code(
        epoch(%{"reducer" => %{"id" => "r", "version" => -1}}),
        :invalid_reducer_envelope
      )

      assert_code(
        epoch(%{"reducer" => %{"id" => "r", "version" => 1.0}}),
        :invalid_reducer_envelope
      )
    end

    test "base must be a JSON object" do
      assert_code(epoch(%{"base" => []}), :invalid_reducer_envelope)
      assert_code(epoch(%{"base" => nil}), :invalid_reducer_envelope)
    end

    test "an invalid projection name yields invalid_projection_name" do
      err = assert_code(epoch(%{"projection" => "Attributes"}), :invalid_projection_name)
      assert err.projection == "Attributes"

      assert_code(epoch(%{"projection" => "1x"}), :invalid_projection_name)
      assert_code(epoch(%{"projection" => 5}), :invalid_projection_name)
    end

    test "a valid epoch carries its projection on nothing (it is not an error)" do
      assert {:epoch, _} = Envelope.classify(epoch(%{"projection" => "a.b_c/d-e"}))
    end
  end

  describe "operation envelope (§10)" do
    test "a well-formed operation body classifies as an operation" do
      body = operation()
      assert {:operation, ^body} = Envelope.classify(body)
    end

    test "an EXTRA field is invalid" do
      assert_code(operation(%{"extra" => 1}), :invalid_reducer_envelope)
    end

    test "a missing field is invalid" do
      for key <- ["version", "projection", "epoch_id", "operation"] do
        assert_code(operation() |> Map.delete(key), :invalid_reducer_envelope)
      end
    end

    test "version must be integer 1" do
      assert_code(operation(%{"version" => 2}), :invalid_reducer_envelope)
    end

    test "epoch_id must be a lowercase canonical UUID" do
      assert_code(operation(%{"epoch_id" => String.upcase(@uuid)}), :invalid_reducer_envelope)
      assert_code(operation(%{"epoch_id" => nil}), :invalid_reducer_envelope)
    end

    test "operation must be a JSON object" do
      assert_code(operation(%{"operation" => "put"}), :invalid_reducer_envelope)
      assert_code(operation(%{"operation" => []}), :invalid_reducer_envelope)
      assert_code(operation(%{"operation" => nil}), :invalid_reducer_envelope)
    end

    test "an invalid projection name yields invalid_projection_name" do
      assert_code(operation(%{"projection" => "Attributes"}), :invalid_projection_name)
    end
  end
end
