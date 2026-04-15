class TerminalSession < ActiveRecord::Base
  # fields: project_id:integer, owner_id:integer, pty_cmd:string, cols:integer, rows:integer, status:string

  belongs_to :project
  belongs_to :owner, class_name: 'User', foreign_key: 'owner_id', optional: true
end
