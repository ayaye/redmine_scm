# frozen_string_literal: true

class ScmGithubController < ApplicationController
  before_action :require_login
  before_action :find_project
  before_action :authorize_manage_repository
  before_action :find_repository, only: %i[refresh_mirror register_webhook]

  def test_connection
    repository = find_optional_repository
    result = GithubCreator.test_connection(
      url: params[:github_url],
      token: submitted_token.presence || repository&.password,
      repository: repository
    )
    render json: result, status: result[:ok] ? :ok : :unprocessable_entity
  end

  def refresh_mirror
    if @repository.fetch_changesets
      flash[:notice] = l(:notice_github_mirror_refreshed)
    else
      flash[:error] = @repository.mirror_last_error.presence || l(:error_github_mirror_refresh_failed)
    end
    redirect_to edit_repository_path(@repository)
  end

  def register_webhook
    if @repository.register_secure_hook
      flash[:notice] = l(:notice_github_webhook_registered)
    else
      flash[:error] = @repository.extra_info&.fetch('extra_hook_error', nil) || l(:warning_github_hook_registration_failed)
    end
    redirect_to edit_repository_path(@repository)
  end

  private

  def find_project
    @project = Project.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def authorize_manage_repository
    deny_access unless User.current.allowed_to?(:manage_repository, @project)
  end

  def find_repository
    @repository = @project.repositories.find(params[:repository_id])
    render_404 unless @repository.is_a?(Repository::Github)
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_optional_repository
    return if params[:repository_id].blank?

    repository = @project.repositories.find_by(id: params[:repository_id])
    repository if repository.is_a?(Repository::Github)
  end

  def submitted_token
    token = params[:github_token].to_s
    token unless token.blank? || token.match?(/\Ax{15}\z/)
  end
end
