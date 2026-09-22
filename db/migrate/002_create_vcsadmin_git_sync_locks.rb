# frozen_string_literal: true

class CreateVcsadminGitSyncLocks < ActiveRecord::Migration[6.1]
  def change
    create_table :vcsadmin_git_sync_locks do |t|
      t.integer :repository_id, null: false
      t.string :token, null: false
      t.datetime :locked_until, null: false
      t.timestamps null: false
    end

    add_index :vcsadmin_git_sync_locks, :repository_id, unique: true
    add_index :vcsadmin_git_sync_locks, :locked_until
  end
end
