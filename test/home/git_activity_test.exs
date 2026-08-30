defmodule Home.GitActivityTest do
  use ExUnit.Case, async: true

  alias Home.GitActivity

  test "normalizes supported GitHub origin formats" do
    expected = "https://github.com/owner/project"

    assert GitActivity.github_url("git@github.com:owner/project.git") == expected
    assert GitActivity.github_url("ssh://git@github.com/owner/project.git") == expected
    assert GitActivity.github_url("https://github.com/owner/project.git") == expected
    assert GitActivity.github_url("http://github.com/owner/project") == expected
  end

  test "ignores non-GitHub origins" do
    assert GitActivity.github_url("git@gitlab.com:owner/project.git") == nil
    assert GitActivity.github_url(nil) == nil
  end
end
