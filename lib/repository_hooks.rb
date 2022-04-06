class RepositoryHooks < Redmine::Hook::ViewListener
  # Renders the checkout URL
  #
  # Context:
  # * :project => Current project
  # * :repository => Current Repository
  #
  def view_repositories_show_contextual(context={})
    return unless context[:repository].present? && 
        context[:request].params[:action] == "show" &&
        context[:controller].instance_variable_get("@path").empty?

    if context[:repository].url.start_with?('/')
      repository_url = context[:request].base_url + context[:repository].url
    else
      repository_url = context[:repository].url
    end

    if context[:repository].scm_name == 'Subversion'
      repository_cmd = 'svn co ' + repository_url
    elsif context[:repository].scm_name == 'Git'
      repository_cmd = 'git clone --recursive ' + repository_url
    else
      # TODO: Support more systems.
      return
    end

    # Display Smart HTTP button for http/https repos. 
    repository_http = repository_url.start_with?('http')

    context.merge!({
      :repository_url => repository_url,
      :repository_cmd => repository_cmd,
      :repository_http => repository_http,
    })

    options = {:partial => "redmine_checkout_hooks/view_repositories_show_contextual"}
    context[:hook_caller].send(:render, {:locals => context}.merge(options))
  end
  alias_method :view_repositories_list_contextual, :view_repositories_show_contextual
end
