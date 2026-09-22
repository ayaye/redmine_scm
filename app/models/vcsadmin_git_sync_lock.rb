# frozen_string_literal: true

require 'securerandom'

class VcsadminGitSyncLock < ApplicationRecord
  class << self
    def with_repository_lock(repository, ttl: 300)
      token = SecureRandom.hex(24)
      row = ensure_row(repository.id)
      acquired = where(id: row.id).
        where('locked_until < ? OR token = ?', Time.current, token).
        update_all(token: token, locked_until: Time.current + ttl, updated_at: Time.current)
      return false unless acquired == 1

      begin
        yield
      ensure
        where(id: row.id, token: token).
          update_all(locked_until: Time.at(0), updated_at: Time.current)
      end
      true
    end

    private

    def ensure_row(repository_id)
      find_or_create_by!(repository_id: repository_id) do |row|
        row.token = SecureRandom.hex(24)
        row.locked_until = Time.at(0)
      end
    rescue ActiveRecord::RecordNotUnique
      find_by!(repository_id: repository_id)
    end
  end
end
