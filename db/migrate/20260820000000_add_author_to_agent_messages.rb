class AddAuthorToAgentMessages < ActiveRecord::Migration[8.1]
  def change
    # Per-message author for shared agent conversations (#79). The worker is
    # the authority for identity and stores only the stable user_id; the
    # display name is resolved at read/broadcast time via User#display_name
    # (no denormalized snapshot that can go stale).
    #
    # user_id is nullable: system/assistant/tool rows have no author.
    add_column :agent_messages, :user_id, :bigint
    add_foreign_key :agent_messages, :users, column: :user_id
  end
end
