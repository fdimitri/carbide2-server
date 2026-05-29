require "test_helper"

require 'minitest/autorun'
class SmokeSubstrateTest < Minitest::Test
  # Seed Project 1 in test DB if missing
  def setup
    unless Project.find_by(id: 1)
      Project.create!(id: 1, name: "workspace-1")
    end
  end
  # No fixtures needed for substrate smoke test
  def test_project_1_exists_and_has_root_path
    p = Project.find_by(id: 1)
    assert p, "Project 1 should exist"
    assert p.project_setting, "Project 1 should have project_setting"
    assert_equal "/srv/projects/1", p.project_setting.root_path
  end

  def test_FS_loader_class_present
    assert defined?(FsLoader), "FsLoader should be defined"
  end
end