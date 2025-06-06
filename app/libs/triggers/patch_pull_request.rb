class Triggers::PatchPullRequest
  def self.call(release, commit)
    new(release, commit).call
  end

  def initialize(release, commit)
    @release = release
    @commit = commit
    @pull_request = Triggers::PullRequest.new(
      release: release,
      new_pull_request_attrs: {phase: :mid_release, kind: :back_merge, release_id: release.id, state: :open, commit_id: commit.id},
      to_branch_ref: working_branch,
      from_branch_ref: patch_branch,
      title: pr_title,
      description: pr_description,
      existing_pr: commit.pull_request,
      patch_pr: true,
      patch_commit: commit
    )
  end

  def call
    @pull_request.create_and_merge!
  end

  private

  delegate :logger, to: Rails
  delegate :train, to: :release
  delegate :working_branch, :continuous_backmerge_branch_prefix, to: :train
  attr_reader :release, :commit

  def pr_title
    "[PATCH] [#{release.release_version}] #{commit.message.split("\n").first}".gsub(/\s*\(#\d+\)/, "").squish
  end

  def pr_description
    <<~TEXT
      - Cherry-pick #{commit.commit_hash} commit
      - Authored by: @#{commit.author_login || commit.author_name}

      #{commit.message}
    TEXT
  end

  def patch_branch
    [continuous_backmerge_branch_prefix, "patch", working_branch, commit.short_sha].compact_blank.join("-")
  end
end
