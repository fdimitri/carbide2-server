require 'test_helper'

# Peak-hours windows are stored AS ENTERED: days, times, and the zone those
# times are in (Agent::WEEKDAYS / TIME_OF_DAY). These tests pin the storage
# contract: a valid window passes, a malformed one fails loudly rather than
# being silently coerced, and the column round-trips through both an Array
# (Postgres) and a JSON String (SQLite).
class AgentTest < ActiveSupport::TestCase
  def build_agent(**attrs)
    Agent.new({
      slug:         attrs[:slug] || 'test-agent',
      name:         'Test Agent',
      provider_url: 'http://localhost:1234/v1',
      model:        'test-model',
      role:         'general',
    }.merge(attrs))
  end

  test 'no peak hours by default' do
    agent = build_agent
    assert_equal [], agent.peak_hours_windows
    assert agent.valid?
  end

  test "accepts a window with its own zone, stored as entered" do
    agent = build_agent(peak_hours: [
      { 'days' => %w[mon tue wed thu fri], 'start' => '21:00', 'end' => '00:00',
        'tz' => 'America/New_York' },
    ])
    assert agent.valid?, agent.errors.full_messages.join(', ')
    assert_equal [{ 'days' => %w[mon tue wed thu fri], 'start' => '21:00',
                    'end' => '00:00', 'tz' => 'America/New_York' }],
                 agent.peak_hours_windows
  end

  test 'accepts a window that crosses midnight' do
    agent = build_agent(peak_hours: [{ 'days' => ['fri'], 'start' => '23:00',
                                       'end' => '01:00', 'tz' => 'UTC' }])
    assert agent.valid?, agent.errors.full_messages.join(', ')
  end

  test 'empty days means every day and is preserved' do
    agent = build_agent(peak_hours: [{ 'days' => [], 'start' => '00:00',
                                       'end' => '06:00', 'tz' => 'UTC' }])
    assert agent.valid?, agent.errors.full_messages.join(', ')
    assert_equal [], agent.peak_hours_windows.first['days']
  end

  test 'an absent zone is stored empty, meaning UTC' do
    agent = build_agent(peak_hours: [{ 'days' => ['mon'], 'start' => '09:00', 'end' => '17:00' }])
    assert agent.valid?, agent.errors.full_messages.join(', ')
    assert_equal '', agent.peak_hours_windows.first['tz']
  end

  test 'accepts a zone ActiveSupport knows by name' do
    agent = build_agent(peak_hours: [{ 'days' => ['mon'], 'start' => '09:00',
                                       'end' => '17:00', 'tz' => 'Eastern Time (US & Canada)' }])
    assert agent.valid?, agent.errors.full_messages.join(', ')
  end

  test 'rejects an unknown timezone' do
    agent = build_agent(peak_hours: [{ 'days' => ['mon'], 'start' => '09:00',
                                       'end' => '17:00', 'tz' => 'Mars/Olympus' }])
    refute agent.valid?
    assert_match(/unknown timezone/, agent.errors[:peak_hours].join)
  end

  test 'rejects an unknown weekday' do
    agent = build_agent(peak_hours: [{ 'days' => ['monday'], 'start' => '09:00', 'end' => '17:00' }])
    refute agent.valid?
    assert_match(/invalid day/, agent.errors[:peak_hours].join)
  end

  test 'rejects a non-HH:MM start time' do
    agent = build_agent(peak_hours: [{ 'days' => ['mon'], 'start' => '9am', 'end' => '17:00' }])
    refute agent.valid?
    assert_match(/HH:MM/, agent.errors[:peak_hours].join)
  end

  test 'rejects an out-of-range time' do
    agent = build_agent(peak_hours: [{ 'days' => ['mon'], 'start' => '24:00', 'end' => '25:00' }])
    refute agent.valid?
  end

  test 'rejects a zero-length window' do
    agent = build_agent(peak_hours: [{ 'days' => ['mon'], 'start' => '09:00', 'end' => '09:00' }])
    refute agent.valid?
    assert_match(/same/, agent.errors[:peak_hours].join)
  end

  test 'rejects a non-array payload' do
    agent = build_agent(peak_hours: { 'start' => '09:00' })
    refute agent.valid?
  end

  test 'normalizes a JSON string column (SQLite) the same as an Array (Postgres)' do
    agent = build_agent
    agent[:peak_hours] = '[{"days":["sat"],"start":"02:00","end":"03:00","tz":"Europe/Berlin"}]'
    assert agent.valid?, agent.errors.full_messages.join(', ')
    assert_equal [{ 'days' => ['sat'], 'start' => '02:00', 'end' => '03:00', 'tz' => 'Europe/Berlin' }],
                 agent.peak_hours_windows
  end

  test 'assignment of a non-array clears the field' do
    agent = build_agent
    agent.peak_hours = [{ 'days' => ['mon'], 'start' => '09:00', 'end' => '17:00', 'tz' => 'UTC' }]
    agent.peak_hours = nil
    assert_equal [], agent.peak_hours_windows
    assert agent.valid?
  end
end
