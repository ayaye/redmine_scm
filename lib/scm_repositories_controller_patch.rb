# frozen_string_literal: true

module ScmRepositoriesControllerPatch
  def self.prepended(base)
    base.before_action :deny_scm_repository_deletion, only: :destroy
  end

  def create
    interface = ScmCreator.interface(params[:repository_scm])
    return super unless handle_with_scm_creator?(interface)

    if create_operation?
      sanitized = interface.sanitize('url' => @repository.url)
      @repository.url = sanitized['url'] if sanitized.key?('url')
    end
    create_repository_with_scm(@repository, interface) if @repository.valid? && create_operation?
    enforce_repository_registration_policy(@repository)

    if @repository.errors.empty? && @repository.save
      redirect_to settings_project_path(@project, tab: 'repositories')
    else
      no_store
      render action: 'new'
    end
  end

  def update
    super
    return unless @repository.is_a?(Repository::Github)
    return unless params.dig(:repository, :register_hook).to_s == '1'
    return if @repository.reload.extra_hook_registered

    flash[:warning] = @repository.extra_info&.fetch('extra_hook_error', nil) || l(:warning_github_hook_registration_failed)
  end

  def destroy
    return super unless @repository.created_with_scm
    return unless params[:confirm]

    @repository.created_with_scm = false unless params[:confirm_with_scm]
    flash[:warning] = l(:warning_repository_deletion_failed) unless @repository.destroy
    redirect_to settings_project_path(@project, tab: 'repositories')
  end

  private

  def deny_scm_repository_deletion
    return unless @repository.created_with_scm && ActiveModel::Type::Boolean.new.cast(ScmConfig['deny_delete'])

    Rails.logger.info "SCM Creator denied deletion of #{@repository.root_url}"
    render_403
  end

  def create_operation?
    params[:operation].to_s == 'add'
  end

  def handle_with_scm_creator?(interface)
    creator_available = interface && interface < ScmCreator && interface.enabled?
    (creator_available && (create_operation? || ActiveModel::Type::Boolean.new.cast(ScmConfig['only_creator']))) ||
      !ActiveModel::Type::Boolean.new.cast(ScmConfig['allow_add_local'])
  end

  def create_repository_with_scm(repository, interface)
    if repository_limit_reached?
      repository.errors.add(:base, :scm_repositories_maximum_count_exceeded, max: ScmConfig['max_repos'].to_i)
      return
    end

    name = interface.repository_name(repository.url)
    unless name
      repository.errors.add(:url, :should_be_of_format_local, repository_format: interface.repository_format)
      return
    end

    repository_path = interface.default_path(name)
    if interface.repository_exists?(name)
      repository.errors.add(:url, :already_exists)
      return
    end

    interface.execute(ScmConfig['pre_create'], repository_path, @project)
    result = interface.create_repository(repository_path, repository)
    unless result
      repository.errors.add(:base, :scm_repository_creation_failed)
      return
    end

    repository_path = result if result.is_a?(String)
    interface.execute(ScmConfig['post_create'], repository_path, @project)
    repository.created_with_scm = true
    repository.root_url = interface.access_root_url(repository_path, repository)
    repository.url = interface.access_url(repository_path, repository)
    flash[:warning] = l(:text_cannot_be_used_redmine_auth) if interface.local? && !interface.belongs_to_project?(name, @project.identifier)
  ensure
    if repository.errors.any?
      repository.root_url = nil
      repository.url = nil
    end
  end

  def enforce_repository_registration_policy(repository)
    return if defined?(Repository::VcsadminGit) && repository.is_a?(Repository::VcsadminGit)

    if ActiveModel::Type::Boolean.new.cast(ScmConfig['only_creator']) && request.post? && repository.errors.empty? && !repository.created_with_scm
      repository.errors.add(:base, :scm_only_creator)
    elsif !ActiveModel::Type::Boolean.new.cast(ScmConfig['allow_add_local']) && request.post? && repository.errors.empty? &&
          !repository.created_with_scm && repository.url.to_s.match?(%r{\A(file://|([a-z]:)?\.*[\\/])}i)
      repository.errors.add(:base, :scm_local_repositories_denied)
    end
  end

  def repository_limit_reached?
    maximum = ScmConfig['max_repos'].to_i
    maximum.positive? && @project.repositories.where(created_with_scm: true).count >= maximum
  end
end
