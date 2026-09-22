# frozen_string_literal: true

require 'time'

module VcsadminGit
  module Mapper
    ACTIONS = {
      'added' => 'A',
      'modified' => 'M',
      'deleted' => 'D',
      'renamed' => 'R',
      'copied' => 'C',
      'type_changed' => 'M'
    }.freeze

    module_function

    def revision(commit, include_paths: false)
      unless commit.is_a?(Hash) && commit['parent_ids'].is_a?(Array) &&
             valid_person?(commit['author']) && valid_person?(commit['committer']) &&
             commit['message'].is_a?(String) &&
             (!include_paths || commit['changes'].is_a?(Array))
        raise InvalidResponseError, 'VCSAdmin response contains invalid commit data'
      end
      identifier = commit_id(commit['id'])
      parents = Array(commit['parent_ids']).map {|parent| commit_id(parent)}
      Redmine::Scm::Adapters::VcsadminGitAdapter::Revision.new(
        identifier: identifier,
        scmid: identifier,
        name: commit['abbreviated_id'],
        author: identity(commit['author']),
        committer: identity(commit['committer']),
        time: parse_time(commit['date'] || commit.dig('committer', 'date'), required: true),
        author_time: parse_time(commit.dig('author', 'date'), required: true),
        message: commit['message'].to_s,
        parents: parents,
        paths: include_paths ? changes(commit['changes']) : []
      )
    end

    def changes(items)
      Array(items).filter_map do |item|
        raise InvalidResponseError, 'VCSAdmin response contains an invalid change' unless item.is_a?(Hash)

        action = ACTIONS[item['change_type']]
        next unless action

        {
          action: action,
          path: with_leading_slash(repository_path(item['path'])),
          from_path: item['previous_path'].present? ?
            with_leading_slash(repository_path(item['previous_path'])) : nil
        }
      end
    end

    def identity(person)
      return '' unless person.is_a?(Hash)

      name = person['name'].to_s
      email = person['email'].to_s
      email.present? ? "#{name} <#{email}>" : name
    end

    def valid_person?(person)
      person.is_a?(Hash) && person['name'].is_a?(String) &&
        person['email'].is_a?(String) && person['date'].is_a?(String)
    end

    def parse_time(value, required: false)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      raise InvalidResponseError, 'VCSAdmin response contains an invalid date' if required

      nil
    end

    def commit_id(value)
      string = value.to_s
      unless string.match?(/\A[0-9a-f]{40,64}\z/)
        raise InvalidResponseError, 'VCSAdmin response contains an invalid commit ID'
      end

      string
    end

    def repository_path(value)
      string = value.to_s
      if string.blank? || string.start_with?('/', '\\') || string.include?("\0") ||
         string.bytesize > 4096 ||
         string.tr('\\', '/').split('/').any? {|segment| segment.blank? || %w[. ..].include?(segment)}
        raise InvalidResponseError, 'VCSAdmin response contains an invalid repository path'
      end

      string
    end

    def with_leading_slash(path)
      value = path.to_s
      value.start_with?('/') ? value : "/#{value}"
    end
  end
end
