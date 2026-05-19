require 'test_helper'

# Tests for FsDocument — the in-memory line buffer used by DirectoryEntry#calc_current
class FsDocumentTest < ActiveSupport::TestCase

  setup do
    @doc = FsDocument.new
  end

  # ---------------------------------------------------------------------------
  # set_contents / get_contents
  # ---------------------------------------------------------------------------

  test "set_contents stores text and get_contents returns it" do
    @doc.set_contents("hello world")
    assert_equal "hello world", @doc.get_contents
  end

  test "set_contents with multi-line text" do
    @doc.set_contents("line one\nline two\nline three")
    assert_equal "line one\nline two\nline three", @doc.get_contents
  end

  test "set_contents replaces previous content" do
    @doc.set_contents("first")
    @doc.set_contents("second")
    assert_equal "second", @doc.get_contents
  end

  test "set_contents with empty string" do
    @doc.set_contents("something")
    @doc.set_contents("")
    assert_equal "", @doc.get_contents
  end

  # ---------------------------------------------------------------------------
  # insertDataSingleLine
  # ---------------------------------------------------------------------------

  test "insertDataSingleLine inserts characters at start of line" do
    @doc.set_contents("hello world")
    msg = { 'data' => '>>> ', 'startLine' => 0, 'startChar' => 0 }
    @doc.do_insert_data_single_line(nil, msg)
    assert_equal ">>> hello world", @doc.get_contents
  end

  test "insertDataSingleLine inserts characters in the middle of a line" do
    @doc.set_contents("hello world")
    msg = { 'data' => 'beautiful ', 'startLine' => 0, 'startChar' => 6 }
    @doc.do_insert_data_single_line(nil, msg)
    assert_equal "hello beautiful world", @doc.get_contents
  end

  test "insertDataSingleLine appends to end of line" do
    @doc.set_contents("hello")
    msg = { 'data' => ' world', 'startLine' => 0, 'startChar' => 5 }
    @doc.do_insert_data_single_line(nil, msg)
    assert_equal "hello world", @doc.get_contents
  end

  test "insertDataSingleLine on second line of multi-line document" do
    @doc.set_contents("line one\nline two\nline three")
    msg = { 'data' => 'INSERTED ', 'startLine' => 1, 'startChar' => 5 }
    @doc.do_insert_data_single_line(nil, msg)
    assert_equal "line one\nline INSERTED two\nline three", @doc.get_contents
  end

  test "insertDataSingleLine accepts JSON string payload" do
    @doc.set_contents("abc")
    msg = { 'data' => 'X', 'startLine' => 0, 'startChar' => 1 }.to_json
    @doc.do_insert_data_single_line(nil, msg)
    assert_equal "aXbc", @doc.get_contents
  end

  # ---------------------------------------------------------------------------
  # deleteDataSingleLine
  # ---------------------------------------------------------------------------

  test "deleteDataSingleLine removes characters from a line" do
    @doc.set_contents("hello world")
    msg = { 'startLine' => 0, 'startChar' => 0, 'endChar' => 6 }
    @doc.do_delete_data_single_line(nil, msg)
    assert_equal "world", @doc.get_contents
  end

  test "deleteDataSingleLine removes characters from the middle" do
    @doc.set_contents("hello beautiful world")
    msg = { 'startLine' => 0, 'startChar' => 6, 'endChar' => 16 }
    @doc.do_delete_data_single_line(nil, msg)
    assert_equal "hello world", @doc.get_contents
  end

  test "deleteDataSingleLine on a specific line in multi-line doc" do
    @doc.set_contents("line one\nline two\nline three")
    msg = { 'startLine' => 1, 'startChar' => 0, 'endChar' => 5 }
    @doc.do_delete_data_single_line(nil, msg)
    assert_equal "line one\ntwo\nline three", @doc.get_contents
  end

  # ---------------------------------------------------------------------------
  # insertDataMultiLine
  # ---------------------------------------------------------------------------

  test "insertDataMultiLine inserts a newline splitting a line" do
    @doc.set_contents("hello world")
    msg = { 'data' => "\n", 'startLine' => 0, 'startChar' => 5 }
    @doc.do_insert_data_multi_line(nil, msg)
    assert_equal "hello\n world", @doc.get_contents
  end

  test "insertDataMultiLine inserts multiple lines" do
    @doc.set_contents("first\nlast")
    msg = { 'data' => "second\nthird\n", 'startLine' => 0, 'startChar' => 5 }
    @doc.do_insert_data_multi_line(nil, msg)
    result = @doc.get_contents
    assert_includes result, "second"
    assert_includes result, "third"
  end

  # ---------------------------------------------------------------------------
  # deleteDataMultiLine
  # ---------------------------------------------------------------------------

  test "deleteDataMultiLine removes content spanning two lines" do
    @doc.set_contents("line one\nline two\nline three")
    # Delete from line 0 char 5 through line 1 char 5 — removes "one\nline "
    # Keeps "line " from line 0 and "two" from line 1 → joins to "line two"
    msg = { 'startLine' => 0, 'startChar' => 5, 'endLine' => 1, 'endChar' => 5 }
    @doc.do_delete_data_multi_line(nil, msg)
    assert_equal "line two\nline three", @doc.get_contents
  end

end
