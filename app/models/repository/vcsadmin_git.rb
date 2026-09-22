# frozen_string_literal: true

require_dependency 'repository'
require_relative '../../../lib/redmine/scm/adapters/vcsadmin_git_adapter'
require_relative '../../../lib/vcsadmin_git/client'
require_relative '../vcsadmin_git_sync_lock'

class Repository::VcsadminGit < Repository
  SYNC_MODE_DEFAULT_BRANCH = 'default_branch'
  SYNC_PHASES = %w[
    pending initial_import initial_reconcile complete incremental_import incremental_reconcile error
  ].freeze

  safe_attributes 'vcsadmin_repository_id', 'vcsadmin_sync_mode'

  validates_presence_of :url, :login, :password
  validates :root_url, format: {with: /\A[1-9][0-9]*\z/}, allow_blank: true
  validate :validate_vcsadmin_mapping, if: :validate_remote_mapping?

  validate :validate_vcsadmin_configuration
  validate :validate_vcsadmin_repository_url
  before_validation :normalize_vcsadmin_repository_url
  before_validation :initialize_vcsadmin_metadata

  class << self
    def scm_adapter_class
      Redmine::Scm::Adapters::VcsadminGitAdapter
    end

    def scm_name
      'VCSAdmin Git'
    end

    def scm_available
      scm_adapter_class.client_available
    end

    def changeset_identifier(changeset)
      changeset.scmid
    end

    def format_changeset_identifier(changeset)
      changeset.revision.to_s[0, 8]
    end
  end

  def password=(value)
    return password if persisted? && value.blank?

    @vcsadmin_api_client = nil
    super
  end

  def login=(value)
    @vcsadmin_api_client = nil
    super
  end

  def url=(value)
    @vcsadmin_api_client = nil
    @vcsadmin_configuration = nil
    super
  end

  def vcsadmin_repository_id
    metadata['extra_vcsadmin_repository_id'].presence || root_url
  end

  def vcsadmin_repository_id=(value)
    string = value.to_s.strip
    previous = vcsadmin_repository_id.to_s
    reset_vcsadmin_sync_metadata if previous.present? && previous != string
    merge_vcsadmin_metadata('extra_vcsadmin_repository_id' => string)
    self.root_url = string
    @vcsadmin_mapping_changed = previous != string
  end

  def vcsadmin_repository_name
    metadata['extra_vcsadmin_repository_name']
  end

  def vcsadmin_default_branch
    metadata['extra_vcsadmin_default_branch']
  end

  def vcsadmin_sync_mode
    metadata['extra_vcsadmin_sync_mode'].presence || SYNC_MODE_DEFAULT_BRANCH
  end

  def vcsadmin_sync_mode=(value)
    mode = value.to_s
    mode = SYNC_MODE_DEFAULT_BRANCH unless mode == SYNC_MODE_DEFAULT_BRANCH
    merge_vcsadmin_metadata('extra_vcsadmin_sync_mode' => mode)
  end

  def vcsadmin_sync_status
    metadata['extra_vcsadmin_sync_status'].presence || 'pending'
  end

  def vcsadmin_initial_import_status
    phase = metadata['extra_vcsadmin_sync_phase'].presence || 'pending'
    return 'error' if vcsadmin_last_error.present?
    return 'complete' if %w[complete incremental_import incremental_reconcile].include?(phase)
    return 'error' if phase == 'error'

    phase
  end

  def vcsadmin_last_success_at
    parse_metadata_time('extra_vcsadmin_last_success_at')
  end

  def vcsadmin_last_error
    @vcsadmin_runtime_error.presence || metadata['extra_vcsadmin_last_error']
  end

  def supports_annotate?
    false
  end

  def supports_directory_revisions?
    true
  end

  def supports_revision_graph?
    true
  end

  def report_last_commit
    false
  end

  def repo_log_encoding
    'UTF-8'
  end

  def default_branch
    vcsadmin_default_branch.presence || scm.default_branch
  end

  def scm_entries(path = nil, identifier = nil)
    scm.entries(path, identifier)
  end
  protected :scm_entries

  def latest_changesets(path, revision, limit = 10)
    revisions = scm.revisions(path, nil, revision, limit: limit)
    return [] if revisions.blank?

    by_scmid = changesets.where(scmid: revisions.map(&:scmid)).index_by(&:scmid)
    revisions.each do |item|
      next if by_scmid.key?(item.scmid)

      by_scmid[item.scmid] = save_vcsadmin_revision(scm.commit(item.scmid))
    end
    revisions.filter_map {|item| by_scmid[item.scmid]}
  end

  def find_changeset_by_name(name)
    result = super
    return result if result || name.blank? || !persisted?
    return nil unless name.to_s.match?(/\A[0-9A-Za-z._-]{1,255}\z/) && !name.to_s.start_with?('-')

    revision = scm.commit(name)
    save_vcsadmin_revision(revision)
  end

  def fetch_changesets
    return false unless persisted?

    request_budget = [
      configuration.initial_import_batch_size,
      configuration.sync_batch_size
    ].max + configuration.max_pages_per_sync + 2
    ttl = request_budget *
          (configuration.read_timeout * (configuration.retry_count + 1) + configuration.max_retry_after) + 60
    executed = VcsadminGitSyncLock.with_repository_lock(self, ttl: ttl) do
      synchronize_vcsadmin_changesets
    end
    unless executed
      @vcsadmin_runtime_error = I18n.t(:error_vcsadmin_sync_in_progress)
      return false
    end
    true
  rescue ActiveRecord::StatementInvalid => e
    logger.error "VCSAdmin Git sync lock unavailable for repository #{id}: #{e.class}"
    record_sync_error(I18n.t(:error_vcsadmin_sync_migration_required))
    false
  rescue ::VcsadminGit::Error => e
    log_api_error('synchronize', e)
    record_sync_error(localized_api_error(e))
    false
  rescue Redmine::Scm::Adapters::CommandFailed => e
    logger.error "VCSAdmin Git synchronization failed for repository #{id}: #{e.message}"
    record_sync_error(I18n.t(:error_vcsadmin_sync_failed))
    false
  end

  def save_vcsadmin_revision(revision)
    existing = changesets.find_by(scmid: revision.scmid)
    return existing if existing

    transaction do
      existing = changesets.lock.find_by(scmid: revision.scmid)
      next existing if existing

      parents = changesets.where(scmid: Array(revision.parents)).to_a
      changeset = Changeset.create!(
        repository: self,
        revision: revision.identifier,
        scmid: revision.scmid,
        committer: revision.author.to_s.truncate(255),
        committed_on: revision.time || Time.current,
        comments: revision.message,
        parents: parents
      )
      Array(revision.paths).each {|change| changeset.create_change(change)}
      changeset
    end
  rescue ActiveRecord::RecordNotUnique
    changesets.find_by(scmid: revision.scmid)
  end

  private

  def normalize_vcsadmin_repository_url
    base_url, repository_id = ::VcsadminGit::Configuration.split_repository_url(url)
    return if repository_id.blank?

    self.url = base_url if base_url != url
    self.vcsadmin_repository_id = repository_id if repository_id != vcsadmin_repository_id.to_s
  end

  def validate_vcsadmin_configuration
    configuration
  rescue ArgumentError
    logger.error "VCSAdmin Git configuration is invalid for repository #{id || 'new'}"
    errors.add(:base, :vcsadmin_configuration_invalid)
  end

  def validate_vcsadmin_repository_url
    errors.add(:url, :vcsadmin_repository_url_required) if vcsadmin_repository_id.blank?
  end

  def initialize_vcsadmin_metadata
    data = metadata
    data['extra_vcsadmin_sync_mode'] ||= SYNC_MODE_DEFAULT_BRANCH
    data['extra_vcsadmin_sync_phase'] ||= 'pending'
    data['extra_vcsadmin_sync_status'] ||= 'pending'
    self.extra_info = data
  end

  def validate_remote_mapping?
    new_record? || @vcsadmin_mapping_changed || will_save_change_to_login? || will_save_change_to_password?
  end

  def validate_vcsadmin_mapping
    return if vcsadmin_repository_id.blank? || login.blank? || password.blank? || errors.any?

    api = api_client
    api.verify!
    remote = api.repository(vcsadmin_repository_id)
    unless compatible_remote?(remote)
      errors.add(:base, :vcsadmin_repository_incompatible)
      return
    end
    merge_vcsadmin_metadata(
      'extra_vcsadmin_repository_name' => remote['name'].to_s,
      'extra_vcsadmin_default_branch' => remote['default_branch'].to_s
    )
  rescue ::VcsadminGit::Error => e
    log_api_error('validate_mapping', e)
    errors.add(:base, localized_api_error(e))
  end

  def synchronize_vcsadmin_changesets
    api_client.verify!
    details = api_client.repository(vcsadmin_repository_id)
    unless compatible_remote?(details)
      raise ::VcsadminGit::MissingCapabilityError.new(
        'VCSAdmin repository capabilities changed',
        code: 'missing_capability'
      )
    end
    refresh_remote_metadata(details)
    phase = metadata['extra_vcsadmin_sync_phase'].presence || 'pending'
    start_initial_import(details) if phase == 'pending'
    start_incremental_import(details) if metadata['extra_vcsadmin_sync_phase'] == 'complete' &&
                                         details['head_commit_id'].present? &&
                                         details['head_commit_id'] != metadata['extra_vcsadmin_last_head']

    process_sync_batches
  end

  def start_initial_import(details)
    if details['head_commit_id'].blank?
      persist_sync_metadata(
        'extra_vcsadmin_sync_phase' => 'complete',
        'extra_vcsadmin_sync_status' => 'ready',
        'extra_vcsadmin_last_success_at' => Time.current.utc.iso8601
      )
      return
    end
    persist_sync_metadata(
      'extra_vcsadmin_sync_phase' => 'initial_import',
      'extra_vcsadmin_sync_status' => 'importing',
      'extra_vcsadmin_sync_revision' => details['head_commit_id'],
      'extra_vcsadmin_sync_cursor' => nil,
      'extra_vcsadmin_sync_boundary' => nil,
      'extra_vcsadmin_last_error' => nil
    )
  end

  def start_incremental_import(details)
    persist_sync_metadata(
      'extra_vcsadmin_sync_phase' => 'incremental_import',
      'extra_vcsadmin_sync_status' => 'importing',
      'extra_vcsadmin_sync_revision' => details['head_commit_id'],
      'extra_vcsadmin_sync_cursor' => nil,
      'extra_vcsadmin_sync_boundary' => metadata['extra_vcsadmin_last_head'],
      'extra_vcsadmin_last_error' => nil
    )
  end

  def process_sync_batches
    pages = 0
    commits_processed = 0
    phase = metadata['extra_vcsadmin_sync_phase']
    limit = phase.start_with?('initial_') ? configuration.initial_import_batch_size : configuration.sync_batch_size

    while pages < configuration.max_pages_per_sync && commits_processed < limit
      phase = metadata['extra_vcsadmin_sync_phase']
      break if phase == 'complete'

      processed =
        if phase.end_with?('_import')
          process_import_page(limit - commits_processed)
        elsif phase.end_with?('_reconcile')
          process_reconcile_page(limit - commits_processed)
        else
          0
        end
      commits_processed += processed
      pages += 1
      break if processed.zero? && metadata['extra_vcsadmin_sync_phase'] != 'complete'
    end

    if metadata['extra_vcsadmin_sync_phase'] == 'complete'
      persist_sync_metadata(
        'extra_vcsadmin_sync_status' => 'ready',
        'extra_vcsadmin_last_success_at' => Time.current.utc.iso8601,
        'extra_vcsadmin_last_error' => nil
      )
    else
      persist_sync_metadata(
        'extra_vcsadmin_sync_status' => 'importing',
        'extra_vcsadmin_last_success_at' => Time.current.utc.iso8601,
        'extra_vcsadmin_last_error' => nil
      )
    end
  end

  def process_import_page(remaining)
    page = api_client.commits(
      vcsadmin_repository_id,
      revision: metadata['extra_vcsadmin_sync_revision'],
      limit: [configuration.page_size, remaining].min,
      cursor: metadata['extra_vcsadmin_sync_cursor']
    )
    commits = Array(page['commits'])
    boundary = metadata['extra_vcsadmin_sync_boundary']
    reached_boundary = false

    commits.each do |item|
      if boundary.present? && item['id'] == boundary
        reached_boundary = true
        break
      end
      next if changesets.exists?(scmid: item['id'])

      detail = api_client.commit(vcsadmin_repository_id, item['id'])
      save_vcsadmin_revision(::VcsadminGit::Mapper.revision(detail, include_paths: true))
    end

    pagination = page.fetch('pagination')
    if pagination['truncated']
      raise ::VcsadminGit::ResponseTooLargeError.new(
        'VCSAdmin pagination boundary reached',
        code: 'pagination_truncated'
      )
    end
    if reached_boundary || pagination['next_cursor'].blank?
      next_phase = metadata['extra_vcsadmin_sync_phase'].sub('_import', '_reconcile')
      persist_sync_metadata(
        'extra_vcsadmin_sync_phase' => next_phase,
        'extra_vcsadmin_sync_cursor' => nil
      )
    else
      persist_sync_metadata('extra_vcsadmin_sync_cursor' => pagination['next_cursor'])
    end
    commits.length
  end

  def process_reconcile_page(remaining)
    page = api_client.commits(
      vcsadmin_repository_id,
      revision: metadata['extra_vcsadmin_sync_revision'],
      limit: [configuration.page_size, remaining].min,
      cursor: metadata['extra_vcsadmin_sync_cursor']
    )
    commits = Array(page['commits'])
    boundary = metadata['extra_vcsadmin_sync_boundary']
    reached_boundary = false
    commits.each do |item|
      if boundary.present? && item['id'] == boundary
        reached_boundary = true
        break
      end
      reconcile_parents(item)
    end
    pagination = page.fetch('pagination')
    if pagination['truncated']
      raise ::VcsadminGit::ResponseTooLargeError.new(
        'VCSAdmin pagination boundary reached',
        code: 'pagination_truncated'
      )
    end
    if reached_boundary || pagination['next_cursor'].blank?
      persist_sync_metadata(
        'extra_vcsadmin_sync_phase' => 'complete',
        'extra_vcsadmin_sync_cursor' => nil,
        'extra_vcsadmin_last_head' => metadata['extra_vcsadmin_sync_revision'],
        'extra_vcsadmin_sync_boundary' => nil
      )
    else
      persist_sync_metadata('extra_vcsadmin_sync_cursor' => pagination['next_cursor'])
    end
    commits.length
  end

  def reconcile_parents(item)
    changeset = changesets.find_by(scmid: item['id'])
    return unless changeset

    parents = changesets.where(scmid: Array(item['parent_ids'])).to_a
    missing = parents - changeset.parents.to_a
    changeset.parents << missing if missing.any?
  end

  def refresh_remote_metadata(details)
    persist_sync_metadata(
      'extra_vcsadmin_repository_name' => details['name'].to_s,
      'extra_vcsadmin_default_branch' => details['default_branch'].to_s
    )
  end

  def compatible_remote?(remote)
    remote['type'] == 'git' && remote['read_only'] == true &&
      (::VcsadminGit::Client::REQUIRED_CAPABILITIES - Array(remote['capabilities'])).empty?
  end

  def api_client
    @vcsadmin_api_client ||= ::VcsadminGit::Client.new(
      username: login,
      password: password,
      configuration: configuration
    )
  end

  def configuration
    @vcsadmin_configuration ||= ::VcsadminGit::Configuration.current(url)
  end

  def metadata
    (extra_info || {}).dup
  end

  def merge_vcsadmin_metadata(values)
    self.extra_info = metadata.merge(values)
  end

  def reset_vcsadmin_sync_metadata
    data = metadata
    data.keys.grep(/\Aextra_vcsadmin_(?:repository_name|default_branch|sync_|last_)/).each do |key|
      data.delete(key)
    end
    self.extra_info = data
  end

  def persist_sync_metadata(values)
    data = metadata.merge(values)
    data.delete_if {|_key, value| value.nil?}
    self.extra_info = data
    update_column(:extra_info, data) if persisted?
  end

  def record_sync_error(message, status: 'error')
    persist_sync_metadata(
      'extra_vcsadmin_sync_phase' => (metadata['extra_vcsadmin_sync_phase'].presence || 'error'),
      'extra_vcsadmin_sync_status' => status,
      'extra_vcsadmin_last_error' => message.to_s.truncate(500)
    )
  rescue StandardError
    false
  end

  def parse_metadata_time(key)
    Time.zone.parse(metadata[key]) if metadata[key].present?
  rescue ArgumentError
    nil
  end

  def localized_api_error(error)
    key =
      case error
      when ::VcsadminGit::AuthenticationError then :error_vcsadmin_authentication
      when ::VcsadminGit::TlsError then :error_vcsadmin_tls
      when ::VcsadminGit::DnsError then :error_vcsadmin_dns
      when ::VcsadminGit::ConnectionRefusedError then :error_vcsadmin_connection_refused
      when ::VcsadminGit::ConnectTimeoutError then :error_vcsadmin_connect_timeout
      when ::VcsadminGit::ReadTimeoutError then :error_vcsadmin_read_timeout
      when ::VcsadminGit::IncompatibleApiError then :error_vcsadmin_api_version
      when ::VcsadminGit::MissingCapabilityError then :error_vcsadmin_capability
      when ::VcsadminGit::NotFoundError then :error_vcsadmin_repository_not_accessible
      when ::VcsadminGit::ResponseTooLargeError then :error_vcsadmin_response_too_large
      when ::VcsadminGit::TemporaryServiceError then :error_vcsadmin_service_unavailable
      when ::VcsadminGit::InvalidResponseError then :error_vcsadmin_invalid_response
      else :error_vcsadmin_connection
      end
    I18n.t(key)
  end

  def log_api_error(operation, error)
    remote_repository_name = vcsadmin_repository_name.to_s.gsub(/[\r\n\t]/, ' ').squish
    logger.error(
      "VCSAdmin Git #{operation} failed repository=#{id || 'new'} " \
      "remote_repository=#{vcsadmin_repository_id} " \
      "remote_repository_name=#{remote_repository_name.inspect} status=#{error.http_status} " \
      "code=#{error.code} request_id=#{error.request_id}"
    )
  end
end
