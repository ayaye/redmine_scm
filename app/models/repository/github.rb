require_dependency File.expand_path('../../../../lib/adapters/github_adapter', __FILE__)

class Repository::Github < Repository::Git # TODO
    before_save :set_local_url

    # TODO validate

    def self.scm_adapter_class
        Redmine::Scm::Adapters::GithubAdapter
    end

    def self.scm_name
        'Github'
    end

    def extra_report_last_commit
        true
    end

    def fetch_changesets
        if File.directory?(ScmConfig['github']['path'])
            scm_brs = branches
            if scm_brs.blank?
                path = File.dirname(root_url)
                Dir.mkdir(path) unless File.directory?(path)
                Rails.logger.info "Cloning #{url} to #{root_url}"
                scm.clone
            elsif File.directory?(root_url)
                Rails.logger.info "Fetching updates for #{root_url}" # FIXME
                #scm.fetch
            end
        end
        super
    end

    def clear_extra_info_of_changesets
    end

protected

    def set_local_url
        if new_record? && url.present? && root_url.blank? && ScmConfig['github'] && ScmConfig['github']['path']
            self.root_url = ScmConfig['github']['path'] + '/' + url.gsub(%r{^.*[@/]github.com[:/]}, '')
        end
    end

end
