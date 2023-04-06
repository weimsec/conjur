# frozen_string_literal: true

require 'rest_client'
require 'json_schemer'
require 'factories/renderer'

module Factories
  class CreateFromPolicyFactory
    def initialize(renderer: Factories::Renderer.new, http: RestClient, schema_validator: JSONSchemer)
      @renderer = renderer
      @http = http
      @schema_validator = schema_validator

      # JSON, URI, and Base64 are defined here for visibility. They
      # are not currently mocked in testing, thus, we're not setting
      # them in the initializer.
      @json = JSON
      @uri = URI

      # Defined here for visibility. We shouldn't need to mock these.
      @success = SuccessResponse
      @failure = FailureResponse
    end

    def call(factory_template:, request_body:, account:, authorization:)
      validate_and_transform_request(
        schema: factory_template.schema,
        params: request_body
      ).bind do |body_variables|
        # Convert `dashed` keys to `underscored`.  This only occurs for top-level parameters.
        # Conjur variables should be use dashes rather than underscores.
        template_variables = body_variables.transform_keys { |key| key.to_s.underscore }

        # Push rendered policy to the desired policy branch
        @renderer.render(template: factory_template.policy_namespace, variables: template_variables)
          .bind do |policy_load_path|
            valid_variables = factory_template.schema['properties'].keys - ['variables']
            render_and_apply_policy(
              policy_load_path: policy_load_path,
              policy_template: factory_template.policy,
              variables: template_variables.select { |k, _| valid_variables.include?(k) },
              account: account,
              authorization: authorization
            ).bind do |result|
              return @success.new(result) unless factory_template.schema['properties'].key?('variables')

              # Set Policy Factory variables
              @renderer.render(template: "#{factory_template.policy_namespace}/<%= id %>", variables: template_variables)
                .bind do |variable_path|
                  set_factory_variables(
                    schema_variables: factory_template.schema['properties']['variables']['properties'],
                    factory_variables: template_variables['variables'],
                    variable_path: variable_path,
                    authorization: authorization,
                    account: account
                  )
                end
                .bind {
                  # If variables were added successfully, return the result so that
                  # we send the policy load response back to the client.
                  @success.new(result)
                }
            end
          end
      end
    end

    private

    def validate_and_transform_request(schema:, params:)
      return @failure.new("Request body must be JSON", status: :bad_request) if params.blank?

      begin
        params = @json.parse(params)
      rescue
        return @failure.new("Request body must be valid JSON", status: :bad_request)
      end

      # Strip keys without values
      params = params.select{|_, v| v.present? }

      validator = @schema_validator.schema(schema)
      return @success.new(params) if validator.valid?(params)

      errors = validator.validate(params).map do |error|
        case error['type']
        when 'required'
          missing_attributes = error['details']['missing_keys'].map{|key| [ error['data_pointer'], key].reject(&:empty?).join('/') } #.join("', '")
          missing_attributes.map do |attribute|
            {
              message: "Missing JSON key or value for: '#{attribute}'",
              key: attribute
            }
          end
        else
          {
            message: "Generic JSON Schema validation error: type => '#{error['type']}', details => '#{error['type'].inspect}'"
          }
        end
      end
      @failure.new(errors.flatten, status: :bad_request)
    end

    def render_and_apply_policy(policy_load_path:, policy_template:, variables:, account:, authorization:)
      @renderer.render(
        template: policy_template,
        variables: variables
      ).bind do |rendered_policy|
        response = @http.post(
          "http://localhost:3000/policies/#{account}/policy/#{policy_load_path}",
          rendered_policy,
          'Authorization' => authorization
        )
        if response.code == 201
          @success.new(response.body)
        else
          case response.code
          when 400
            @failure.new("Failed to apply generated Policy to '#{policy_load_path}'", status: :bad_request)
          when 401
            @failure.new("Unauthorized to apply generated policy to '#{policy_load_path}'", status: :unauthorized)
          when 403
            @failure.new("Forbidden to apply generated policy to '#{policy_load_path}'", status: :forbidden)
          when 404
            @failure.new("Unable to apply generated policy to '#{policy_load_path}'", status: :not_found)
          else
            @failure.new(
              "Failed to apply generated policy to '#{policy_load_path}'. Status Code: '#{response.code}, Response: '#{response.body}''",
              status: :bad_request
            )
          end
        end
      end
    end

    def set_factory_variables(schema_variables:, factory_variables:, variable_path:, authorization:, account:)
      schema_variables.each_key do |factory_variable|
        next unless factory_variables.key?(factory_variable)

        variable_id = @uri.encode_www_form_component("#{variable_path}/#{factory_variable}")
        secret_path = "secrets/#{account}/variable/#{variable_id}"

        response = @http.post(
          "http://localhost:3000/#{secret_path}",
          factory_variables[factory_variable].to_s,
          { 'Authorization' => authorization }
        )
        next if response.code == 201

        case response.code
        when 401
          return @failure.new("Role is unauthorized to set variable: '#{secret_path}'", status: :unauthorized)
        when 403
          return @failure.new("Role lacks the privilege to set variable: '#{secret_path}'", status: :forbidden)
        else
          return @failure.new(
            "Failed to set variable: '#{secret_path}'. Status Code: '#{response.code}', Response: '#{response.body}'",
            status: :bad_request
          )
        end
      end
      @success.new('Variables successfully set')
    end
  end
end