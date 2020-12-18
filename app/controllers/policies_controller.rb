# frozen_string_literal: true

require 'multipart_parser/reader'

class PoliciesController < RestController
  include FindResource
  include AuthorizeResource

  before_action :current_user
  before_action :find_or_create_root_policy

  rescue_from Sequel::UniqueConstraintViolation, with: :concurrent_load

  # Conjur policies are YAML documents, so we assume that if no content-type
  # is provided in the request.
  set_default_content_type_for_path(%r{^/policies}, 'application/x-yaml')

  def put
    load_policy(:update, Loader::ReplacePolicy, true)
  end

  def patch
    load_policy(:update, Loader::ModifyPolicy, true)
  end

  def post
    load_policy(:create, Loader::CreatePolicy, false)
  end

  protected

  # Returns newly created roles
  def perform(policy_action)
    policy_action.call
    new_actor_roles = actor_roles(policy_action.new_roles)
    create_roles(new_actor_roles)

  end

  def policy_text
    case request.content_type
    when 'multipart/form-data'
      multipart_data[:policy]
    else
      request.raw_post
    end
  end

  def policy_context
    multipart_data.reject { |k,v| k == :policy }
  end

  def multipart_data
    if 'multipart/form-data' == request.content_type
      @multipart_data ||= Util::Multipart.parse_multipart_data(
        request.raw_post,
        content_type: request.headers['CONTENT_TYPE']
      )
    else
      {}
    end
  end

  def find_or_create_root_policy
    Loader::Types.find_or_create_root_policy(account)
  end

  private

  def load_policy(action, loader_class, delete_permitted)
    authorize(action)

    policy = save_submitted_policy(delete_permitted: delete_permitted)
    loaded_policy = loader_class.from_policy(policy, context: policy_context)
    created_roles = perform(loaded_policy)
    audit_success(policy)

    render(json: {
      created_roles: created_roles,
      version: policy[:version]
    }, status: :created)
  rescue => e
    audit_failure(e, action)
    raise e
  end

  def audit_success(policy)
    policy.policy_log.lazy.map(&:to_audit_event).each do |event|
      Audit.logger.log(event)
    end
  end

  def audit_failure(err, operation)
    Audit.logger.log(
      Audit::Event::Policy.new(
        operation: operation,
        subject: {}, # Subject is empty because no role/resource has been impacted
        user: current_user,
        client_ip: request.ip,
        error_message: err.message
      )
    )
  end

  def concurrent_load(_exception)
    response.headers['Retry-After'] = retry_delay
    render(json: {
      error: {
        code: "policy_conflict",
        message: "Concurrent policy load in progress, please retry"
      }
    }, status: :conflict)
  end

  # Delay in seconds to advise the client to wait before retrying on conflict.
  # It's randomized to avoid request bunching.
  def retry_delay
    rand(1..8)
  end

  def save_submitted_policy(delete_permitted:)
    policy_version = PolicyVersion.new(
      role: current_user,
      policy: resource,
      policy_text: policy_text,
      client_ip: request.ip
    )
    policy_version.delete_permitted = delete_permitted
    policy_version.save
  end

  def actor_roles(roles)
    roles.select do |role|
      %w[user host].member?(role.kind)
    end
  end

  def create_roles(actor_roles)
    actor_roles.each_with_object({}) do |role, memo|
      credentials = Credentials[role: role] || Credentials.create(role: role)
      role_id = role.id
      memo[role_id] = { id: role_id, api_key: credentials.api_key }
    end
  end
end
