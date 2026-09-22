# frozen_string_literal: true

class ScmHook < Redmine::Hook::ViewListener
  render_on :view_layouts_base_html_head, partial: 'scm_creator/header'
  render_on :view_projects_form, partial: 'projects/scm'
  render_on :view_repositories_show_contextual, partial: 'repositories/url'
end
