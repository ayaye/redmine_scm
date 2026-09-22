# frozen_string_literal: true

require 'redmine/scm/adapters/git_adapter'
require 'base64'
require 'open3'
require 'shellwords'
require 'uri'

module Redmine
  module Scm
    module Adapters
      class GithubAdapter < GitAdapter
        class << self
          def strip_credential(command)
            super(command).
              gsub(%r{(https://)[^/@\s]+@}, '\\1xxxx@').
              gsub(/(Authorization:\s*Basic\s+)[A-Za-z0-9+\/=]+/i, '\\1xxxx')
          end
        end

        def clone
          secure_remote_git('clone', '--mirror', url, root_url)
        rescue ScmCommandAborted => e
          logger.error "SCM Creator GitHub mirror clone failed: #{e.message}"
          false
        end

        def fetch
          secure_remote_git('--git-dir', root_url, 'fetch', '--quiet', '--all', '--prune')
        rescue ScmCommandAborted => e
          logger.error "SCM Creator GitHub mirror fetch failed: #{e.message}"
          false
        end

        private

        def secure_remote_git(*arguments)
          environment = {'GIT_TERMINAL_PROMPT' => '0'}
          if @login.present? && @password.present? && url.start_with?('https://')
            environment.merge!(
              'GIT_CONFIG_COUNT' => '1',
              'GIT_CONFIG_KEY_0' => 'http.extraHeader',
              'GIT_CONFIG_VALUE_0' => "Authorization: Basic #{Base64.strict_encode64("#{@login}:#{@password}")}"
            )
          end

          command = Shellwords.split(self.class.client_command.to_s) + arguments.map(&:to_s)
          _stdout, stderr, status = Open3.capture3(environment, *command)
          return true if status.success?

          message = stderr.to_s.lines.last.to_s.strip.presence || "git exited with status #{status.exitstatus}"
          raise ScmCommandAborted, strip_credential(message)
        rescue Errno::ENOENT => e
          raise ScmCommandAborted, e.message
        end
      end
    end
  end
end
