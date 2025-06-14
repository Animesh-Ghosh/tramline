# == Schema Information
#
# Table name: store_submissions
#
#  id                      :uuid             not null, primary key
#  approved_at             :datetime
#  config                  :jsonb
#  failure_reason          :string
#  last_stable_status      :string
#  name                    :string
#  parent_release_type     :string           indexed => [parent_release_id]
#  prepared_at             :datetime
#  rejected_at             :datetime
#  sequence_number         :integer          default(0), not null, indexed
#  status                  :string           not null
#  store_link              :string
#  store_release           :jsonb
#  store_status            :string
#  submitted_at            :datetime
#  type                    :string           not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  build_id                :uuid             not null, indexed
#  parent_release_id       :uuid             indexed => [parent_release_type]
#  release_platform_run_id :uuid             not null, indexed
#
class GoogleFirebaseSubmission < StoreSubmission
  # include Sandboxable
  using RefinedArray
  include Displayable

  MAX_NOTES_LENGTH = 16_380
  DEEP_LINK = "https://appdistribution.firebase.google.com/testerapps/"
  UploadNotComplete = Class.new(StandardError)

  STAMPABLE_REASONS = %w[
    triggered
    finished
    failed
  ]

  STATES = {
    created: "created",
    preprocessing: "preprocessing",
    preparing: "preparing",
    finished: "finished",
    failed: "failed",
    failed_with_action_required: "failed_with_action_required"
  }

  enum :failure_reason, {
    unknown_failure: "unknown_failure",
    build_not_found: "build_not_found"
  }.merge(Installations::Google::Firebase::Error.reasons.zip_map_self).merge(Installations::Google::Firebase::OpError.reasons.zip_map_self)

  enum :status, STATES
  aasm safe_state_machine_params do
    state :created, initial: true
    state(*STATES.keys)

    event :preprocess, after_commit: :on_preprocess! do
      transitions from: [:created, :failed], to: :preprocessing
    end

    event :prepare, after_commit: :on_prepare! do
      transitions from: [:created, :preprocessing, :failed], to: :preparing
    end

    event :finish, after_commit: :on_finish! do
      after { set_prepared_at! }
      transitions to: :finished
    end

    event :fail, before: :set_failure_context, after_commit: :on_fail! do
      transitions to: :failed
    end
  end

  def retryable? = failed? && last_stable_status != STATES[:created]

  def trigger!
    return unless actionable?
    return unless may_prepare?
    event_stamp!(reason: :triggered, kind: :notice, data: stamp_data)

    if build.has_artifact?
      # try and find/upload the build if we have it
      preprocess!
    elsif app.skip_finding_builds_for_firebase?
      # we do not want to find builds in firebase in this case
      # fail with error since we have no way of completing this submission
      fail_with_error!(BuildNotFound)
    else
      # move to preprocessing regardless and hopefully find it eventually
      preprocess!
    end
  end

  def upload_build!
    return unless may_prepare?

    # try to find before uploading and return early if found
    unless app.skip_finding_builds_for_firebase?
      release_info = provider.find_build(build.build_number, build_version_name, release_platform_run.platform)
      if release_info.ok?
        prepare_and_update!(release_info.value!)
        return
      end
    end

    # if we don't have the build artifact, and we couldn't find it previously, we fail
    unless build.has_artifact?
      fail_with_error!(BuildNotFound)
      return
    end

    # if we have the build artifact, we can try and upload it
    result = nil
    filename = build.artifact.file.filename.to_s
    build.artifact.with_open do |file|
      result = provider.upload(file, filename, platform:)
    end
    if result&.ok?
      # start tracking the upload status asynchronously
      StoreSubmissions::GoogleFirebase::UpdateUploadStatusJob.perform_async(id, result.value!)
    else
      # if we couldn't upload the build artifact, we fail
      fail_with_error!(result&.error)
    end
  end

  # TODO: This should eventually become some sort of config or a generalized feature
  # But for now, this allows us to find the build in Firebase with the version 1.0.0+1 instead of just 1.0.0
  # Note: this is only the case for when the submission is for an AppVariant
  # Note: this will only find by 1.0.0+1, uploads from tramline (if possible) will continue to be 1.0.0
  def build_version_name
    # intentionally referencing the flag here directly, so we can remove this hack easily later
    flag = Flipper.enabled?(:append_build_number_to_version_name, release_platform_run.organization)

    if flag && provider.integrable.is_a?(AppVariant)
      "#{build.version_name}+#{build.build_number}"
    else
      build.version_name
    end
  end

  def update_upload_status!(op_name)
    return unless may_prepare?
    result = provider.get_upload_status(op_name)
    unless result.ok?
      fail_with_error!(result.error)
      return
    end

    op_info = result.value!
    raise UploadNotComplete unless op_info.done?

    prepare_and_update!(op_info.release, op_info.status)
  end

  def update_build_notes!(release_name)
    provider.update_release_notes(release_name, tester_notes)
  end

  def prepare_for_release!
    return unless may_finish?
    return finish! if submission_channel_id == GoogleFirebaseIntegration::EMPTY_CHANNEL[:id].to_s

    deployment_channels = [submission_channel_id]
    result = provider.release(external_id, deployment_channels)
    if result.ok?
      finish!
    else
      fail_with_error!(result.error)
    end
  end

  def provider = conf.integrable.firebase_build_channel_provider

  def notification_params(failure_message: nil)
    super.merge(submission_channel: "#{display} - #{submission_channel.name}")
  end

  def deep_link
    return if external_id.blank?
    parsed_external_id = external_id.split("apps/").last
    DEEP_LINK + parsed_external_id
  end

  private

  def tester_notes
    parent_release.tester_notes.truncate(MAX_NOTES_LENGTH)
  end

  alias_method :release_notes, :tester_notes

  def prepare_and_update!(release_info, build_status = nil)
    transaction do
      prepare!
      update_store_info!(release_info, build_status)
    end

    StoreSubmissions::GoogleFirebase::UpdateBuildNotesJob.perform_async(id, external_id)
  end

  def on_preprocess!
    StoreSubmissions::GoogleFirebase::UploadJob.perform_async(id)
  end

  def on_prepare!
    StoreSubmissions::GoogleFirebase::PrepareForReleaseJob.perform_async(id)
  end

  def on_finish!
    event_stamp!(reason: :finished, kind: :success, data: stamp_data)
    parent_release.rollout_complete!(self)
  end

  def on_fail!(args = nil)
    failure_error = args&.fetch(:error, nil)
    event_stamp!(reason: :failed, kind: :error, data: stamp_data(failure_message: failure_error&.message))
    notify!("Submission failed", :submission_failed, notification_params(failure_message: failure_error&.message))
  end

  def update_store_info!(release_info, build_status)
    self.store_link = release_info.console_link
    self.store_status = build_status
    self.store_release = release_info.release
    save!
  end

  def external_id
    store_release.try(:[], "id")
  end

  def stamp_data(failure_message: nil)
    super.merge(channels: submission_channel.name)
  end
end
