require 'test_helper'
require 'minitest/autorun'
require 'open3'

require_relative '../worker/project_pod'

# Smoke spec for ProjectPod. Exercises the real kubectl flow against the
# cluster the test process is running in: create -> Ready -> stop -> gone.
#
# Designed to be run INSIDE the workspace pod (where kubectl, RBAC, and the
# shell image are all available):
#
#   kubectl -n ws-1 exec deploy/ws-1 -c rails -- \
#     bundle exec rails test test/smoke_project_pod_test.rb
#
# Skips cleanly on a dev laptop without cluster access so the standard
# `bundle exec rails test` run is still green.
class SmokeProjectPodTest < Minitest::Test
  # Use a project id well outside any real seeded data to avoid collisions
  # with a pod a developer may have running.
  TEST_PROJECT_ID = 99_991

  def setup
    skip 'kubectl not on PATH' unless system('which kubectl > /dev/null 2>&1')
    _out, _err, status = Open3.capture3(
      'kubectl', 'get', 'ns', ProjectPod::NAMESPACE,
      '-o', 'name'
    )
    skip "no cluster access (ns=#{ProjectPod::NAMESPACE})" unless status.success?
  end

  def teardown
    # Belt-and-suspenders: nuke the test pod even if an assertion failed
    # mid-flight so we don't leave debris.
    pod = ProjectPod.new(TEST_PROJECT_ID)
    pod.stop!
  rescue StandardError
    # nothing we can do here, test failure already recorded
  end

  def test_exec_cmd_format
    pod = ProjectPod.new(TEST_PROJECT_ID)
    cmd = pod.exec_cmd
    assert_includes cmd, 'kubectl exec'
    assert_includes cmd, "-n #{ProjectPod::NAMESPACE}"
    assert_includes cmd, pod.name
    assert_includes cmd, 'bash -l'
  end

  def test_ensure_running_then_stop
    pod = ProjectPod.new(TEST_PROJECT_ID)

    pod.ensure_running!
    assert_equal 'Running', phase_of(pod.name), 'pod should be Running after ensure_running!'

    # exec a trivial command to prove the pod is actually usable.
    out, _err, status = Open3.capture3(
      'kubectl', 'exec', '-n', ProjectPod::NAMESPACE, pod.name,
      '--', 'sh', '-c', 'echo carbide-smoke-ok'
    )
    assert status.success?, 'kubectl exec into freshly created pod failed'
    assert_includes out, 'carbide-smoke-ok'

    pod.stop!
    # delete is async (--wait=false). Poll briefly for the pod to disappear.
    deadline = Time.now + 30
    loop do
      break if phase_of(pod.name).nil?
      flunk "pod #{pod.name} still present 30s after stop!" if Time.now >= deadline
      sleep 0.5
    end
  end

  private

  def phase_of(name)
    out, _err, status = Open3.capture3(
      'kubectl', 'get', 'pod', '-n', ProjectPod::NAMESPACE, name,
      '-o', 'jsonpath={.status.phase}'
    )
    return nil unless status.success?
    s = out.strip
    s.empty? ? nil : s
  end
end
