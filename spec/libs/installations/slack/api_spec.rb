require "rails_helper"

describe Installations::Slack::Api, type: :integration do
  let(:access_token) { Faker::String.random(length: 8) }

  describe "#list_channels" do
    let(:payload) { JSON.parse(File.read("spec/fixtures/slack/channels.json")) }

    it "returns the transformed list of enabled apps" do
      allow_any_instance_of(described_class).to receive(:execute).with(:get,
        "https://slack.com/api/conversations.list",
        {
          params: {
            limit: 200,
            exclude_archived: true,
            types: "public_channel,private_channel",
            cursor: nil
          }
        })
        .and_return(payload)
      result = described_class.new(access_token).list_channels(SlackIntegration::CHANNELS_TRANSFORMATIONS)

      expected_projects = [
        {
          id: "C012AB3CD",
          name: "general",
          description: "This channel is for team-wide communication and announcements. All team members are in this channel.",
          is_private: false,
          member_count: 4
        },
        {
          id: "C061EG9T2",
          name: "random",
          description: "A place for non-work-related flimflam, faffing, hodge-podge or jibber-jabber you'd prefer to keep out of more focused work-related channels.",
          is_private: false,
          member_count: 4
        }
      ]
      expect(result[:channels]).to match_array(expected_projects)
      expect(result[:next_cursor]).to eq("dGVhbTpDMDYxRkE1UEI=")
    end
  end

  describe "#create_channel" do
    let(:channel_name) { Faker::Alphanumeric.alphanumeric(number: 10) }

    context "when channel does not exist" do
      before do
        allow_any_instance_of(described_class).to receive(:execute).and_return(
          {
            "ok" => true,
            "channel" => {
              "id" => "C08PWJT7YJ2",
              "name" => channel_name,
              "is_private" => false
            }
          }
        )
      end

      it "returns transformed response" do
        response = described_class.new(access_token).create_channel(SlackIntegration::CREATE_CHANNEL_TRANSFORMATIONS, channel_name)
        expect(response).to include({id: "C08PWJT7YJ2", name: channel_name, is_private: false})
      end
    end

    context "when channel already exists" do
      before do
        allow_any_instance_of(described_class).to receive(:execute).and_return(
          {
            "ok" => false,
            "error" => "name_taken"
          }
        )
      end

      it "raises error" do
        expect { described_class.new(access_token).create_channel(SlackIntegration::CREATE_CHANNEL_TRANSFORMATIONS, channel_name) }
          .to raise_error(Installations::Error) { |error|
            expect(error.reason).to eq("name_taken")
          }
      end
    end
  end
end
