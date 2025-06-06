require "google/cloud/bigquery"
require "json"

module Installations
  class Crashlytics::Api
    BIGQUERY = ::Google::Cloud::Bigquery

    attr_reader :json_key, :project_number

    def initialize(project_number, json_key)
      @project_number = project_number
      @json_key = json_key
    end

    def find_release(bundle_identifier, platform, app_version, app_version_code, start_date, transforms)
      execute do
        crash_data = fetch_crash_data(bundle_identifier, platform.upcase, app_version, app_version_code, start_date)
        return if crash_data.blank?
        Installations::Response::Keys.transform([crash_data], transforms).first
      end
    end

    def datasets
      execute do
        target_datasets = {}

        # datasets will appear sorted by time
        bigquery_client.datasets.each do |dataset|
          case dataset.dataset_id
          when /^analytics_\d+$/
            target_datasets[:ga4] ||= dataset_pattern(dataset)
          when /crashlytics/i
            target_datasets[:crashlytics] ||= dataset_pattern(dataset)
          else
            Rails.logger.warn("Dataset ID does not match expected datasets: #{dataset.dataset_id}")
          end
        end

        target_datasets
      end
    end

    private

    def fetch_crash_data(bundle_identifier, platform, app_version, app_version_code, start_date)
      aq = analytics_query(datasets[:ga4], bundle_identifier, platform, app_version, start_date)
      analytics_data = get_data(aq).find { |a| a[:version_name] == app_version } || {}
      cq = crashlytics_query(datasets[:crashlytics], bundle_identifier, platform, app_version, app_version_code, start_date)
      crashlytics_data = get_data(cq).find { |a| a[:version_name] == app_version } || {}
      analytics_data.merge(crashlytics_data)
    end

    def bigquery_client
      @bigquery_client ||= BIGQUERY.new(credentials: key_file)
    end

    def dataset_pattern(dataset)
      "#{dataset.project_id}.#{dataset.dataset_id}.*"
    end

    def get_data(query)
      execute { bigquery_client.query(query) }
    end

    def crashlytics_query(dataset_name, bundle_identifier, platform, version_name, version_code, start_date)
      table_name = dataset_name.sub("*", "") + bundle_identifier.tr(".", "_") + "_" + platform + "*"
      start_timestamp = date_to_bq_date(start_date)
      <<-SQL.squish
        WITH combined_events AS (
          SELECT
            issue_id,
            application.display_version AS version_name,
            application.build_version AS version_code,
            event_timestamp,
            bundle_identifier
          FROM `#{table_name}`
          WHERE event_timestamp >= '#{start_timestamp}'
          AND error_type = 'FATAL'
        ),
        errors_with_version AS (
          SELECT
            issue_id,
            version_name,
            version_code
          FROM combined_events
          WHERE version_code = "#{version_code}"
          AND version_name = "#{version_name}"
        ),
        previous_errors AS (
          SELECT DISTINCT issue_id
          FROM combined_events
          WHERE version_code < "#{version_code}"
        ),
        new_errors AS (
          SELECT
            e.issue_id,
            e.version_name,
            e.version_code
          FROM errors_with_version e
          LEFT JOIN previous_errors pe ON e.issue_id = pe.issue_id
          WHERE pe.issue_id IS NULL
        )
        SELECT
          e.version_name AS version_name,
          COUNT(DISTINCT e.issue_id) AS errors_count,
          COUNT(DISTINCT ne.issue_id) AS new_errors_count
        FROM errors_with_version e
        LEFT JOIN new_errors ne ON e.version_code = ne.version_code
        GROUP BY e.version_name
        ORDER BY e.version_name
      SQL
    end

    def analytics_query(dataset_name, bundle_identifier, platform, version_name, start_date)
      table_name = dataset_name.sub("*", "events_*")
      events_table_suffix = start_date.strftime("%Y%m%d")
      <<-SQL.squish
        WITH combined_events AS (
          SELECT
            event_name,
            event_timestamp,
            (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS ga_session_id,
            app_info.version AS version_name,
            user_id,
            user_pseudo_id
          FROM `#{table_name}`
          WHERE
            _TABLE_SUFFIX > '#{events_table_suffix}'
            AND app_info.id = "#{bundle_identifier}"
            AND platform = "#{platform}"
        ),
        total_sessions AS (
            SELECT
              COUNT(DISTINCT CONCAT(user_pseudo_id, ga_session_id)) AS total_sessions_in_last_day,
            FROM
              combined_events
            WHERE
              event_timestamp >= UNIX_MICROS(TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY))
        )
        SELECT
          version_name,
          ts.total_sessions_in_last_day AS total_sessions_in_last_day,
          count(DISTINCT CONCAT(user_pseudo_id, ga_session_id)) as sessions,
          COUNT(DISTINCT COALESCE(user_id, user_pseudo_id)) AS daily_users,
          COUNT(DISTINCT CASE WHEN event_timestamp >= UNIX_MICROS(TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)) THEN CONCAT(user_pseudo_id, ga_session_id) END) AS sessions_in_last_day,
          COUNT(DISTINCT CASE WHEN event_name = 'app_exception' THEN CONCAT(user_pseudo_id, ga_session_id) END) AS sessions_with_errors,
          COUNT(DISTINCT CASE WHEN event_name = 'app_exception' THEN COALESCE(user_id, user_pseudo_id) END) AS daily_users_with_errors
        FROM
          combined_events,
          total_sessions AS ts
        WHERE
          version_name = "#{version_name}"
        GROUP BY
          version_name, ts.total_sessions_in_last_day
        ORDER BY
          version_name;
      SQL
    end

    def key_file
      json_key.rewind
      JSON.parse(json_key.read)
    end

    def execute
      yield if block_given?
    rescue ::Google::Apis::ServerError, ::Google::Apis::ClientError, ::Google::Apis::AuthorizationError => e
      raise Installations::Google::Firebase::Error.new(e)
    rescue ::Google::Cloud::PermissionDeniedError => e
      raise Installations::Crashlytics::Error.new("Authentication failed: #{e.message}")
    end

    def date_to_bq_date(date)
      date.iso8601
    end
  end
end
