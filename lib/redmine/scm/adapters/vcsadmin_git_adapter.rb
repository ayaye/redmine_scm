# frozen_string_literal: true

require 'redmine/scm/adapters/abstract_adapter'
require_relative '../../../vcsadmin_git/configuration'
require_relative '../../../vcsadmin_git/client'
require_relative '../../../vcsadmin_git/mapper'

module Redmine
  module Scm
    module Adapters
      class VcsadminGitAdapter < AbstractAdapter
        class Revision < Redmine::Scm::Adapters::Revision
          attr_accessor :committer, :author_time

          def initialize(attributes = {})
            super
            self.committer = attributes[:committer]
            self.author_time = attributes[:author_time]
          end

          def format_identifier
            identifier.to_s[0, 8]
          end
        end

        class GitBranch < Branch
          attr_accessor :is_default, :latest_commit_date
        end

        class GitTag < String
          attr_accessor :commit_id, :date, :tagger, :annotated
        end

        class RemoteEntry < Entry
          attr_accessor :remote_type, :remote_object_id
        end

        class << self
          def client_command
            ''
          end

          def client_version
            [1, 0, 0]
          end

          def client_available
            true
          end
        end

        def adapter_name
          'VCSAdmin Git'
        end

        def supports_annotate?
          false
        end

        def info
          details = client.repository(repository_id)
          Info.new(root_url: repository_id, lastrev: details['head_commit_id'])
        rescue VcsadminGit::Error => e
          raise_command_error(e)
        end

        def branches
          client.branches(repository_id).map do |item|
            name = validate_ref_name(item['name'])
            commit_id = VcsadminGit::Mapper.commit_id(item['commit_id'])
            branch = GitBranch.new(name)
            branch.revision = commit_id
            branch.scmid = commit_id
            branch.is_default = item['default'] == true
            branch.latest_commit_date = VcsadminGit::Mapper.parse_time(
              item['latest_commit_date'],
              required: item['latest_commit_date'].present?
            )
            branch
          end.sort
        rescue VcsadminGit::Error => e
          raise_command_error(e)
        end

        def tags
          client.tags(repository_id).map do |item|
            tag = GitTag.new(validate_ref_name(item['name']))
            tag.commit_id = VcsadminGit::Mapper.commit_id(item['commit_id'])
            tag.date = VcsadminGit::Mapper.parse_time(item['date'], required: item['date'].present?)
            tag.tagger = item['tagger']
            tag.annotated = item['annotated']
            tag
          end.sort
        rescue VcsadminGit::Error => e
          raise_command_error(e)
        end

        def default_branch
          branch = branches.detect(&:is_default)
          branch&.to_s
        end

        def entries(path = nil, identifier = nil, _options = {})
          tree = client.tree(repository_id, revision: identifier.presence || 'HEAD', path: normalize_path(path, true))
          collection = Entries.new
          Array(tree['entries']).each do |item|
            unless item.is_a?(Hash)
              raise VcsadminGit::InvalidResponseError, 'VCSAdmin returned an invalid tree entry'
            end
            type = item['type'].to_s
            unless %w[file directory symlink submodule].include?(type)
              raise VcsadminGit::InvalidResponseError, 'VCSAdmin returned an invalid tree entry type'
            end
            name = item['name'].to_s
            if name.blank? || name.include?('/') || name.include?('\\') || name.include?("\0") ||
               %w[. ..].include?(name)
              raise VcsadminGit::InvalidResponseError, 'VCSAdmin returned an invalid tree entry name'
            end
            remote_path = client.normalize_path(item['path'])
            entry = RemoteEntry.new(
              name: name,
              path: remote_path,
              kind: type == 'directory' ? 'dir' : 'file',
              size: item['size'],
              lastrev: Revision.new
            )
            entry.remote_type = type
            entry.remote_object_id = item['object_id']
            collection << entry
          end
          collection.sort_by_name
        rescue VcsadminGit::Error => e
          raise_command_error(e)
        end

        def lastrev(path, revision)
          page = client.commits(
            repository_id,
            revision: revision.presence || 'HEAD',
            path: normalize_path(path, true).presence,
            limit: 1
          )
          commit = Array(page['commits']).first
          commit ? VcsadminGit::Mapper.revision(commit) : nil
        rescue VcsadminGit::Error => e
          raise_command_error(e)
        end

        def revisions(path = nil, identifier_from = nil, identifier_to = nil, options = {})
          if identifier_from.present?
            raise ScmCommandAborted, ::I18n.t(:error_vcsadmin_arbitrary_comparison_unsupported)
          end

          limit = [options[:limit].to_i.nonzero? || configuration.page_size, configuration.page_size].min
          normalized_path = normalize_path(path, true)
          data =
            if normalized_path.present?
              client.history(
                repository_id,
                revision: identifier_to.presence || 'HEAD',
                path: normalized_path,
                limit: limit,
                follow_renames: false
              )
            else
              client.commits(repository_id, revision: identifier_to.presence || 'HEAD', limit: limit)
            end
          items = data[normalized_path.present? ? 'history' : 'commits']
          Revisions.new(Array(items).map {|commit| VcsadminGit::Mapper.revision(commit)})
        rescue VcsadminGit::Error => e
          raise_command_error(e)
        end

        def diff(path, identifier_from, identifier_to = nil)
          if identifier_to.present?
            raise ScmCommandAborted, ::I18n.t(:error_vcsadmin_arbitrary_comparison_unsupported)
          end

          result = client.diff(repository_id, identifier_from)
          if result['truncated']
            raise ScmCommandAborted, ::I18n.t(:error_vcsadmin_diff_truncated, limit: result['limit_bytes'])
          end
          result.fetch('diff').lines
        rescue VcsadminGit::Error => e
          raise_command_error(e)
        end

        def cat(path, identifier = nil)
          blob = client.blob(
            repository_id,
            revision: identifier.presence || 'HEAD',
            path: normalize_path(path)
          )
          if blob['size'].to_i > configuration.max_file_bytes
            raise ScmCommandAborted, ::I18n.t(:error_vcsadmin_file_too_large)
          end
          if blob['content'].nil?
            key = blob['content_omitted_reason'] == 'binary_file' ?
              :error_vcsadmin_binary_unavailable : :error_vcsadmin_file_too_large
            raise ScmCommandAborted, ::I18n.t(key)
          end

          blob.fetch('content').to_s.encode('UTF-8', invalid: :replace, undef: :replace)
        rescue VcsadminGit::Error => e
          raise_command_error(e)
        end

        def commit(identifier)
          VcsadminGit::Mapper.revision(client.commit(repository_id, identifier), include_paths: true)
        rescue VcsadminGit::Error => e
          raise_command_error(e)
        end

        def valid_name?(name)
          return false unless name.is_a?(String) && name.bytesize.between?(1, 255)
          return false if name.start_with?('-') || name.include?('\\') || name.match?(/[\x00-\x20\x7f]/)

          true
        end

        def client
          @client ||= VcsadminGit::Client.new(
            username: @login,
            password: @password,
            configuration: configuration
          )
        end

        private

        def repository_id
          @root_url.to_s
        end

        def configuration
          @configuration ||= VcsadminGit::Configuration.current(@url)
        rescue ArgumentError
          raise ScmCommandAborted, ::I18n.t(:error_vcsadmin_configuration)
        end

        def normalize_path(path, allow_empty = false)
          client.normalize_path(path.to_s, allow_empty: allow_empty)
        end

        def validate_ref_name(value)
          name = value.to_s
          unless valid_name?(name)
            raise VcsadminGit::InvalidResponseError, 'VCSAdmin returned an invalid reference name'
          end

          name
        end

        def raise_command_error(error)
          details = []
          details << error.code if error.code.present?
          details << "request #{error.request_id}" if error.request_id.present?
          message = ::I18n.t(:error_vcsadmin_request_failed)
          message = "#{message} (#{details.join(', ')})" if details.any?
          raise ScmCommandAborted, message
        end
      end
    end
  end
end
