# frozen_string_literal: true

require "rails_helper"

describe StoreSubmissions::PlayStore::PrepareForReleaseJob do
  it_behaves_like "lock-acquisition retry behaviour"
end
