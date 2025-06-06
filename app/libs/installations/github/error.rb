module Installations
  class Github::Error < Installations::Error
    ERRORS = [
      {
        resource: "PullRequest",
        code: "custom",
        message_matcher: /No commits between/,
        decorated_reason: :pull_request_without_commits
      },
      {
        resource: "PullRequest",
        code: "custom",
        message_matcher: /A pull request already exists for/,
        decorated_reason: :pull_request_already_exists
      },
      {
        resource: "Hook",
        code: "custom",
        message_matcher: /event cannot have more than 20 hooks/,
        decorated_reason: :webhook_limit_reached
      },
      {
        resource: "Hook",
        code: "custom",
        message_matcher: /Hook already exists on this repository/,
        decorated_reason: :webhook_already_exists
      },
      {
        resource: "Release",
        code: "already_exists",
        decorated_reason: :tagged_release_already_exists
      },
      {
        resource: "Release",
        code: "custom",
        message_matcher: /body is too long (maximum is 125000 characters)/i,
        decorated_reason: :release_notes_too_long
      }
    ]

    MESSAGES = [
      {
        message_matcher: /Not Found/i,
        decorated_reason: :not_found
      },
      {
        message_matcher: /Reference already exists/,
        decorated_reason: :tag_reference_already_exists
      },
      {
        message_matcher: /Pull Request is not mergeable/i,
        decorated_reason: :pull_request_not_mergeable
      },
      {
        message_matcher: /approving review is required by reviewers/i,
        decorated_reason: :pull_request_not_mergeable
      },
      {
        message_matcher: /Merge conflict/i,
        decorated_reason: :merge_conflict
      },
      {
        message_matcher: /Required input\s+.?\w+.?\s+not provided/i,
        decorated_reason: :workflow_parameter_not_provided
      },
      {
        message_matcher: /Workflow does not have 'workflow_dispatch' trigger/i,
        decorated_reason: :workflow_dispatch_missing
      },
      {
        message_matcher: /Changes must be made through a pull request/i,
        decorated_reason: :protected_branch
      },
      {
        message_matcher: /Unexpected inputs provided/i,
        decorated_reason: :workflow_parameter_invalid
      },
      {
        message_matcher: /Merge commits are not allowed on this repository/i,
        decorated_reason: :merge_commits_not_allowed
      }
    ]

    def initialize(api_exception)
      @api_exception = api_exception
      Rails.logger.debug { "Github error: #{api_exception}" }
      super(errors&.first&.fetch("message", nil) || error_message, reason: handle)
    end

    def handle
      return :unknown_failure if match.nil?
      match[:decorated_reason]
    end

    private

    attr_reader :api_exception

    def match
      @match ||= matched_error || matched_message
    end

    def matched_error
      ERRORS.find do |known_error|
        resource = known_error[:resource]
        code = known_error[:code]
        message_matcher = known_error[:message_matcher]

        errors&.any? do |err|
          resource_match = err["resource"].eql?(resource)
          code_match = err["code"].eql?(code)
          msg_match = message_matcher.nil? ? true : err["message"] =~ message_matcher

          resource_match && code_match && msg_match
        end
      end
    end

    def matched_message
      MESSAGES.find { |known_error_message| known_error_message[:message_matcher] =~ error_message }
    end

    def body
      @body ||= JSON.parse(api_exception.response_body)
    end

    def errors
      body["errors"]
    end

    def error_message
      body["message"]
    end
  end
end
