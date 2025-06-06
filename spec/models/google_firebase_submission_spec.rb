require "rails_helper"

describe GoogleFirebaseSubmission do
  before do
    allow(Coordinators::Signals).to receive(:internal_release_finished!)
  end

  it "has a valid factory" do
    expect(create(:google_firebase_submission)).to be_valid
  end

  describe "#trigger!" do
    let(:parent_release) { create(:internal_release) }
    let(:workflow_run) { create(:workflow_run, triggering_release: parent_release) }
    let(:submission) { create(:google_firebase_submission, parent_release:, build: workflow_run.build) }
    let(:providable_dbl) { instance_double(GoogleFirebaseIntegration) }

    before do
      allow_any_instance_of(described_class).to receive(:provider).and_return(providable_dbl)
      allow(providable_dbl).to receive(:project_link)
      allow(providable_dbl).to receive(:public_icon_img)
    end

    it "preprocess when build has an artifact" do
      create(:build_artifact, build: submission.build)
      expected_job = StoreSubmissions::GoogleFirebase::UploadJob
      allow(expected_job).to receive(:perform_async)

      submission.trigger!
      submission.reload

      expect(submission.preprocessing?).to be(true)
      expect(submission.store_link).to be_nil
      expect(expected_job).to have_received(:perform_async).with(submission.id).once
    end

    it "fails when build does not have an artifact and skip_finding_builds_for_firebase? is true" do
      Flipper.enable_actor(:skip_finding_builds_for_firebase, submission.app)

      submission.trigger!

      expect(submission.failed?).to be(true)
    end

    it "preprocess even when build does not have an artifact" do
      submission.trigger!

      expect(submission.preprocessing?).to be(true)
    end
  end

  describe "#upload_build!" do
    let(:parent_release) { create(:internal_release) }
    let(:release_platform_run) { parent_release.release_platform_run }
    let(:workflow_run) { create(:workflow_run, :finished, triggering_release: parent_release) }
    let(:submission) { create(:google_firebase_submission, :preprocessing, build:, release_platform_run:, parent_release:) }
    let(:providable_dbl) { instance_double(GoogleFirebaseIntegration) }

    before do
      allow_any_instance_of(described_class).to receive(:provider).and_return(providable_dbl)
      allow(providable_dbl).to receive(:project_link)
      allow(providable_dbl).to receive(:public_icon_img)
    end

    context "when build has an artifact but is not in store" do
      before do
        allow(providable_dbl).to receive(:find_build).and_return(GitHub::Result.new { raise })
      end

      let(:build) { create(:build, :with_artifact, workflow_run:) }

      it "starts the upload if build has an artifact" do
        expected_job = StoreSubmissions::GoogleFirebase::UpdateUploadStatusJob
        result = 1
        allow(providable_dbl).to receive(:upload).and_return(GitHub::Result.new { result })
        allow(expected_job).to receive(:perform_async)

        submission.upload_build!
        expect(expected_job).to have_received(:perform_async).with(submission.id, result).once
      end

      it "marks failure if upload fails" do
        expected_job = StoreSubmissions::GoogleFirebase::UpdateUploadStatusJob
        result = 1
        error = {
          "error" => {
            "status" => "PERMISSION_DENIED",
            "code" => 403,
            "message" => "The caller does not have permission"
          }
        }
        client_error = Google::Apis::ClientError.new("Error", body: error.to_json)
        error_obj = Installations::Google::Firebase::Error.new(client_error)
        allow(providable_dbl).to receive(:upload).and_return(GitHub::Result.new { raise error_obj })
        allow(expected_job).to receive(:perform_async)

        submission.upload_build!
        expect(submission.failed?).to be(true)
        expect(expected_job).not_to have_received(:perform_async).with(submission.id, result)
      end
    end

    context "when build has an artifact and is in store" do
      let(:build) { create(:build, :with_artifact, workflow_run:) }
      let(:build_info_obj) do
        GoogleFirebaseIntegration::ReleaseInfo.new(
          {
            build_version: "471280959",
            create_time: "2024-07-05T23:51:56.539088Z",
            display_version: "10.31.0",
            firebase_console_uri: Faker::Internet.url,
            name: Faker::Lorem.word,
            release_notes: {text: "NOTES"}
          },
          GoogleFirebaseIntegration::BUILD_TRANSFORMATIONS
        )
      end

      before do
        allow(providable_dbl).to receive(:find_build).and_return(GitHub::Result.new { build_info_obj })
      end

      it "does not start the upload" do
        allow(providable_dbl).to receive(:upload)

        submission.upload_build!

        expect(providable_dbl).not_to have_received(:upload)
      end

      it "finds the build and prepares the submission" do
        expected_job = StoreSubmissions::GoogleFirebase::PrepareForReleaseJob
        allow(expected_job).to receive(:perform_async)

        submission.upload_build!
        submission.reload

        expect(submission.preparing?).to be(true)
        expect(expected_job).to have_received(:perform_async).with(submission.id).once
      end
    end

    context "when build does not have an artifact" do
      let(:build) { create(:build, workflow_run:) }
      let(:build_info_obj) do
        GoogleFirebaseIntegration::ReleaseInfo.new(
          {
            build_version: "471280959",
            create_time: "2024-07-05T23:51:56.539088Z",
            display_version: "10.31.0",
            firebase_console_uri: Faker::Internet.url,
            name: Faker::String.random(length: 10),
            release_notes: {text: "NOTES"}
          },
          GoogleFirebaseIntegration::BUILD_TRANSFORMATIONS
        )
      end

      it "finds the build" do
        expected_job = StoreSubmissions::GoogleFirebase::PrepareForReleaseJob
        allow(providable_dbl).to receive(:find_build).and_return(GitHub::Result.new { build_info_obj })
        allow(expected_job).to receive(:perform_async)

        submission.upload_build!
        submission.reload

        expect(submission.preparing?).to be(true)
        expect(expected_job).to have_received(:perform_async).with(submission.id).once
      end

      it "marks failure if build not found" do
        expected_job = StoreSubmissions::GoogleFirebase::PrepareForReleaseJob
        allow(providable_dbl).to receive(:find_build).and_return(GitHub::Result.new { raise Installations::Error.new("Some Error", reason: :unknown_failure) })
        allow(expected_job).to receive(:perform_async)

        submission.upload_build!
        submission.reload

        expect(submission.failed?).to be(true)
        expect(expected_job).not_to have_received(:perform_async).with(submission.id, build_info_obj.id)
      end
    end

    context "with flag: append_build_number_to_version_name to find the build for a variant" do
      let(:build) { create(:build, workflow_run:) }
      let(:build_info_obj) do
        GoogleFirebaseIntegration::ReleaseInfo.new(
          {
            build_version: "471280959",
            create_time: "2024-07-05T23:51:56.539088Z",
            display_version: "10.31.0",
            firebase_console_uri: Faker::Internet.url,
            name: Faker::Lorem.word,
            release_notes: {text: "NOTES"}
          },
          GoogleFirebaseIntegration::BUILD_TRANSFORMATIONS
        )
      end

      before do
        Flipper.enable_actor(:append_build_number_to_version_name, release_platform_run.organization)
        allow(providable_dbl).to receive(:integrable).and_return(create(:app_variant, bundle_identifier: "variant"))
      end

      it "uses a modified version_name to look for the build externally" do
        allow(providable_dbl).to receive(:find_build).and_return(GitHub::Result.new { build_info_obj })

        submission.upload_build!
        submission.reload

        expected_version_name = "#{build.version_name}+#{build.build_number}"
        expect(providable_dbl).to have_received(:find_build).with(build.build_number, expected_version_name, release_platform_run.platform).once
      end

      it "uses the regular version_name when the provider is not attached to a variant" do
        allow(providable_dbl).to receive_messages(find_build: GitHub::Result.new { build_info_obj }, integrable: release_platform_run.app)

        submission.upload_build!
        submission.reload

        expect(providable_dbl).to have_received(:find_build).with(build.build_number, build.version_name, release_platform_run.platform).once
      end
    end
  end

  describe "#update_upload_status!" do
    let(:parent_release) { create(:internal_release) }
    let(:release_platform_run) { parent_release.release_platform_run }
    let(:workflow_run) { create(:workflow_run, :finished, triggering_release: parent_release) }
    let(:build) { create(:build, :with_artifact, workflow_run:) }
    let(:submission) { create(:google_firebase_submission, :preprocessing, build:, release_platform_run:, parent_release:) }
    let(:providable_dbl) { instance_double(GoogleFirebaseIntegration) }
    let(:op_info) {
      {
        done: true,
        response: {
          result: "SUCCESS",
          release: {
            name: Faker::Lorem.sentence,
            firebaseConsoleUri: Faker::Internet.url
          }
        }
      }
    }
    let(:op_info_obj) { GoogleFirebaseIntegration::ReleaseOpInfo.new(op_info) }

    before do
      allow_any_instance_of(described_class).to receive(:provider).and_return(providable_dbl)
      allow(providable_dbl).to receive(:public_icon_img)
      allow(providable_dbl).to receive(:project_link)
    end

    it "prepares and updates the submission" do
      expected_job = StoreSubmissions::GoogleFirebase::UpdateBuildNotesJob
      allow(providable_dbl).to receive(:get_upload_status).and_return(GitHub::Result.new { op_info_obj })
      allow(expected_job).to receive(:perform_async)

      submission.update_upload_status!("op_name")
      submission.reload

      expect(submission.preparing?).to be(true)
      expect(submission.store_link).to eq(op_info[:response][:release][:firebaseConsoleUri])
      expect(expected_job).to have_received(:perform_async).with(submission.id, op_info[:response][:release][:name]).once
    end

    it "fails if upload check fails" do
      expected_job = StoreSubmissions::GoogleFirebase::UpdateBuildNotesJob
      allow(providable_dbl).to receive(:get_upload_status).and_return(GitHub::Result.new { raise })
      allow(expected_job).to receive(:perform_async)

      submission.update_upload_status!("op_name")
      submission.reload

      expect(submission.failed?).to be(true)
      expect(expected_job).not_to have_received(:perform_async)
    end

    it "throws up if upload is not complete" do
      release_info = {
        done: false,
        response: {
          result: "SUCCESS",
          release: {
            firebaseConsoleUri: Faker::Internet.url
          }
        }
      }
      release_info_obj = GoogleFirebaseIntegration::ReleaseOpInfo.new(release_info)
      allow(providable_dbl).to receive(:get_upload_status).and_return(GitHub::Result.new { release_info_obj })

      expect {
        submission.update_upload_status!("op_name")
      }.to raise_error(GoogleFirebaseSubmission::UploadNotComplete)
    end
  end

  describe "#prepare_release!" do
    let(:workflow_run) { create(:workflow_run, :finished) }
    let(:build) { create(:build, :with_artifact, workflow_run:, commit: workflow_run.commit) }
    let(:release_platform_run) { build.release_platform_run }
    let(:internal_release) {
      create(:internal_release,
        release_platform_run:,
        commit: workflow_run.commit,
        triggered_workflow_run: workflow_run,
        config: {
          submissions: [
            {number: 1,
             submission_type: "GoogleFirebaseSubmission",
             submission_config: {id: :internal, name: "internal testing"}}
          ]
        })
    }
    let(:submission) {
      create(:google_firebase_submission, :with_store_release, :preparing,
        build:, release_platform_run:, parent_release: internal_release)
    }
    let(:providable_dbl) { instance_double(GoogleFirebaseIntegration) }

    before do
      allow_any_instance_of(described_class).to receive(:provider).and_return(providable_dbl)
      allow(providable_dbl).to receive(:public_icon_img)
      allow(providable_dbl).to receive(:project_link)
    end

    it "finishes the release" do
      allow(providable_dbl).to receive(:release).and_return(GitHub::Result.new)

      submission.prepare_for_release!

      expect(submission.finished?).to be(true)
    end

    it "fails if release fails" do
      allow(providable_dbl).to receive(:release).and_return(GitHub::Result.new { raise })

      submission.prepare_for_release!

      expect(submission.finished?).to be(false)
    end
  end

  describe "#provider" do
    let(:app) { create(:app, :android) }
    let(:app_variant) { create(:app_variant, bundle_identifier: "variant_identifier", app_config: app.config) }
    let(:submission) { create(:google_firebase_submission) }

    it "return the variant's integration" do
      app_variant_integration = create(:integration, :with_google_firebase, integrable: app_variant)
      submission.update!(config: submission.config.merge(integrable_id: app_variant.id, integrable_type: "AppVariant"))
      expect(submission.reload.provider).to eq(app_variant_integration.providable)
    end

    it "return the app's integration" do
      app_integration = create(:integration, :with_google_firebase, integrable: app)
      submission.update!(config: submission.config.merge(integrable_id: app.id, integrable_type: "App"))
      expect(submission.reload.provider).to eq(app_integration.providable)
    end
  end

  describe "#retryable?" do
    it "is true when failed and last stable status is not created" do
      submission = create(:google_firebase_submission, status: "failed", last_stable_status: "preparing")
      expect(submission.retryable?).to be(true)
    end

    it "is false when failed and last stable status is created" do
      submission = create(:google_firebase_submission, status: "failed", last_stable_status: "created")
      expect(submission.retryable?).to be(false)
    end
  end
end
