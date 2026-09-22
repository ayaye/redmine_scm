# frozen_string_literal: true

module ScmRepositoriesHelperPatch
  def repository_field_tags(form, repository)
    tags = super
    if ActiveModel::Type::Boolean.new.cast(ScmConfig['only_creator']) && repository.new_record?
      tags << exclusive_action_marker
    end
    tags
  end

  def subversion_field_tags(form, repository)
    add_creator_controls(super, repository, SubversionCreator)
  end

  def mercurial_field_tags(form, repository)
    add_creator_controls(super, repository, MercurialCreator)
  end

  def bazaar_field_tags(form, repository)
    add_creator_controls(super, repository, BazaarCreator)
  end

  def git_field_tags(form, repository)
    add_creator_controls(super, repository, GitCreator)
  end

  def github_field_tags(form, repository)
    url_value = repository.url.presence || params.dig(:repository, :url).presence
    url_value ||= creator_default_value(GithubCreator, repository) if creator_available?(repository, GithubCreator)
    fields = form.text_field(
      :url,
      size: 60,
      required: true,
      disabled: !repository.safe_attribute?('url'),
      value: url_value
    )
    fields << creator_controls(repository, GithubCreator) if repository.new_record?
    fields << content_tag('em', l(:text_github_repository_note_new), class: 'info')

    tags = content_tag('p', fields)
    tags << content_tag('p', form.text_field(:login, size: 30, label: l(:field_github_login)))
    tags << content_tag(
      'p',
      form.password_field(
        :password,
        size: 30,
        label: l(:field_github_api_token),
        name: 'ignore',
        value: ((repository.new_record? || repository.password.blank?) ? '' : ('x' * 15)),
        onfocus: "this.value=''; this.name='repository[password]';",
        onchange: "this.name='repository[password]';"
      ) + content_tag('em', l(:text_github_credentials_note), class: 'info')
    )
    tags << github_connection_test(repository) if GithubCreator.enabled?

    if GithubCreator.can_register_hook?
      tags << content_tag(
        'p',
        form.check_box(:register_hook, disabled: repository.extra_hook_registered) +
          content_tag('span', l(:text_github_register_hook_note), class: 'info')
      )
    end

    unless repository.new_record?
      tags << github_mirror_health(repository)
    end

    if !repository.new_record? && User.current.admin?
      if GithubCreator.webhook_url_available?
        hook_url = GithubCreator.webhook_url(repository)
        hook_field = content_tag('label', l(:field_github_webhook_url))
        hook_field << text_field_tag(:github_webhook_url, hook_url, readonly: true, size: 70)
        hook_field << ' '.html_safe << copy_object_url_link(hook_url)
        hook_field << content_tag('em', l(:text_github_webhook_url_note), class: 'info')
        tags << content_tag('p', hook_field)
      else
        tags << content_tag('p', content_tag('em', l(:text_github_webhook_url_unavailable), class: 'info'))
      end
      if GithubCreator.can_register_hook?
        tags << content_tag(
          'p',
          link_to(
            sprite_icon('link', l(:button_github_register_secure_webhook)),
            register_scm_github_webhook_path(project_id: @project, repository_id: repository),
            class: 'button icon',
            data: {method: 'post'}
          )
        )
      end
    end

    tags << exclusive_action_marker if repository.new_record? && creator_available?(repository, GithubCreator)
    tags
  end

  def vcsadmin_git_field_tags(form, repository)
    current_id = repository.vcsadmin_repository_id.to_s
    base_url = repository.url.presence || params.dig(:repository, :url).presence
    base_url, repository_id_from_url = VcsadminGit::Configuration.split_repository_url(base_url)
    current_id = repository_id_from_url if repository_id_from_url.present?
    repository_url = current_id.present? && base_url.present? ? "#{base_url}/repositories/#{current_id}" : base_url

    tags = content_tag(
      'p',
      form.text_field(
        :url,
        label: l(:field_vcsadmin_base_url),
        value: repository_url,
        size: 70,
        required: true
      ) + content_tag('em', l(:text_vcsadmin_base_url_note), class: 'info')
    )
    tags << content_tag('p', form.text_field(:login, size: 30, label: l(:field_vcsadmin_username)))
    tags << content_tag(
      'p',
      form.password_field(
        :password,
        size: 30,
        label: l(:field_vcsadmin_password),
        name: 'ignore',
        value: ((repository.new_record? || repository.password.blank?) ? '' : ('x' * 15)),
        autocomplete: 'new-password',
        onfocus: "this.value=''; this.name='repository[password]';",
        onchange: "this.name='repository[password]';"
      ) + content_tag('em', l(:text_vcsadmin_credentials_note), class: 'info')
    )
    tags << vcsadmin_connection_test(repository)
    tags << vcsadmin_sync_status(repository) if repository.persisted?
    tags
  end

  def scm_path_info_tag(repository)
    if !repository.new_record? && repository.created_with_scm
      interface = ScmCreator.interface(repository)
      external_url = interface&.external_url(repository)
      return content_tag('em', external_url, class: 'info') if external_url.present?
    end
    super
  end

  private

  def vcsadmin_connection_test(repository)
    button = button_tag(
      sprite_icon('checked', l(:button_vcsadmin_test_connection)),
      type: 'button',
      id: 'scm-vcsadmin-test-connection',
      class: 'button icon',
      data: {
        url: test_scm_vcsadmin_git_connection_path(project_id: @project),
        repository_id: repository.persisted? ? repository.id : nil
      }
    )
    result = content_tag(
      'span',
      '',
      id: 'scm-vcsadmin-test-result',
      class: 'scm-github-test-result',
      role: 'status'
    )
    script = javascript_tag(<<~JS)
      $(function() {
        $('#scm-vcsadmin-test-connection').on('click', function() {
          var button = $(this);
          var result = $('#scm-vcsadmin-test-result').removeClass('error success').text('#{escape_javascript(l(:label_loading))}');
          $.ajax({
            url: button.data('url'),
            method: 'POST',
            dataType: 'json',
            data: {
              vcsadmin_base_url: $('#repository_url').val(),
              vcsadmin_username: $('#repository_login').val(),
              vcsadmin_password: $('#repository_password').val(),
              repository_id: button.data('repository-id')
            }
          }).done(function(data) {
            result.addClass('success').text(data.message);
          }).fail(function(xhr) {
            var data = xhr.responseJSON || {};
            result.addClass('error').text(data.message || '#{escape_javascript(l(:error_vcsadmin_connection))}');
          });
        });
      });
    JS
    content_tag('p', button + ' '.html_safe + result) + script
  end

  def vcsadmin_sync_status(repository)
    rows = []
    rows << content_tag('dt', l(:label_vcsadmin_remote_repository)) +
            content_tag('dd', "#{repository.vcsadmin_repository_name} (#{repository.vcsadmin_repository_id})")
    rows << content_tag('dt', l(:label_vcsadmin_default_branch)) +
            content_tag('dd', repository.vcsadmin_default_branch.presence || '-')
    rows << content_tag('dt', l(:label_vcsadmin_sync_status)) +
            content_tag('dd', l("label_vcsadmin_sync_status_#{repository.vcsadmin_sync_status}",
                                default: repository.vcsadmin_sync_status.to_s.humanize))
    rows << content_tag('dt', l(:label_vcsadmin_initial_import_status)) +
            content_tag('dd', l("label_vcsadmin_initial_status_#{repository.vcsadmin_initial_import_status}",
                                default: repository.vcsadmin_initial_import_status.to_s.humanize))
    rows << content_tag('dt', l(:label_vcsadmin_last_sync)) +
            content_tag('dd', repository.vcsadmin_last_success_at ? format_time(repository.vcsadmin_last_success_at) : '-')
    if repository.vcsadmin_last_error.present?
      rows << content_tag('dt', l(:label_vcsadmin_last_error)) +
              content_tag('dd', repository.vcsadmin_last_error, class: 'error')
    end
    synchronize = link_to(
      sprite_icon('reload', l(:button_vcsadmin_synchronize)),
      synchronize_scm_vcsadmin_git_path(project_id: @project, repository_id: repository),
      class: 'button icon',
      data: {method: 'post'}
    )
    content_tag(
      'fieldset',
      content_tag('legend', l(:label_vcsadmin_sync_information)) +
        content_tag('dl', safe_join(rows), class: 'scm-github-health') +
        content_tag('p', synchronize),
      class: 'scm-github-health-box'
    )
  end

  def add_creator_controls(tags, repository, interface)
    return tags unless creator_available?(repository, interface)

    tags << content_tag('div', creator_controls(repository, interface), class: 'scm-creator-actions')

    unless request.post?
      default_value = creator_default_value(interface, repository)
      tags << javascript_tag("$('#repository_url').val('#{escape_javascript(default_value)}');")
    end
    tags
  end

  def creator_available?(repository, interface)
    repository.new_record? && interface.enabled? && !scm_creator_limit_exceeded?
  end

  def creator_controls(repository, interface)
    return ''.html_safe unless creator_available?(repository, interface)

    button_label = interface == GithubCreator ? :button_create_github_repository : :button_create_new_repository
    submit_tag(
      l(button_label),
      onclick: "$('#repository_operation').val('add');",
      id: 'scm_creator_button'
    ) + hidden_field_tag(:operation, '', id: 'repository_operation')
  end

  def exclusive_action_marker
    content_tag('span', '', class: 'scm-creator-exclusive-action', hidden: true)
  end

  def github_connection_test(repository)
    url = test_scm_github_connection_path(project_id: @project)
    button = button_tag(
      sprite_icon('checked', l(:button_github_test_connection)),
      type: 'button',
      id: 'scm-github-test-connection',
      class: 'button icon',
      data: {url: url, repository_id: repository.persisted? ? repository.id : nil}
    )
    result = content_tag('span', '', id: 'scm-github-test-result', class: 'scm-github-test-result', role: 'status')
    script = javascript_tag(<<~JS)
      $(function() {
        $('#scm-github-test-connection').on('click', function() {
          var button = $(this);
          var result = $('#scm-github-test-result').removeClass('error success').text('#{escape_javascript(l(:label_loading))}');
          var token = $('#repository_password').val();
          $.ajax({
            url: button.data('url'),
            method: 'POST',
            dataType: 'json',
            data: {
              github_url: $('#repository_url').val(),
              github_token: token,
              repository_id: button.data('repository-id')
            }
          }).done(function(data) {
            result.addClass('success').text(data.message);
          }).fail(function(xhr) {
            var data = xhr.responseJSON || {};
            result.addClass('error').text(data.message || '#{escape_javascript(l(:error_github_connection_failed_generic))}');
          });
        });
      });
    JS
    content_tag('p', button + ' '.html_safe + result) + script
  end

  def github_mirror_health(repository)
    status = l("label_github_mirror_status_#{repository.mirror_status}", default: repository.mirror_status.to_s.humanize)
    rows = []
    rows << content_tag('dt', l(:label_github_mirror_status)) + content_tag('dd', status)
    rows << content_tag('dt', l(:label_github_mirror_last_fetch)) +
            content_tag('dd', repository.mirror_last_fetch_at ? format_time(repository.mirror_last_fetch_at) : '-')
    rows << content_tag('dt', l(:label_github_mirror_size)) +
            content_tag('dd', repository.mirror_size_bytes ? number_to_human_size(repository.mirror_size_bytes) : '-')
    if repository.mirror_last_error.present?
      rows << content_tag('dt', l(:label_github_mirror_last_error)) + content_tag('dd', repository.mirror_last_error, class: 'error')
    end
    refresh = link_to(
      sprite_icon('reload', l(:button_github_refresh_mirror)),
      refresh_scm_github_mirror_path(project_id: @project, repository_id: repository),
      class: 'button icon',
      data: {method: 'post'}
    )
    content_tag('fieldset',
                content_tag('legend', l(:label_github_mirror_health)) +
                  content_tag('dl', safe_join(rows), class: 'scm-github-health') +
                  content_tag('p', refresh),
                class: 'scm-github-health-box')
  end

  def creator_default_value(interface, repository)
    name = @project.identifier
    if interface.local? && interface.repository_exists?(name)
      name = "#{name}.#{@project.repositories.where(created_with_scm: true).count}"
    end

    path = interface.default_path(name)
    interface == SubversionCreator ? interface.access_root_url(path, repository) : path
  end

  def scm_creator_limit_exceeded?
    maximum = ScmConfig['max_repos'].to_i
    maximum.positive? && @project.repositories.where(created_with_scm: true).count >= maximum
  end
end
