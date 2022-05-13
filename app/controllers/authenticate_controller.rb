# frozen_string_literal: true

class AuthenticateController < ApplicationController
  include BasicAuthenticator
  include AuthorizeResource
  include CurrentUser
  include FindResource
  include AssumedRole

  def list_authenticators
    # Rails 5 requires parameters to be explicitly permitted before converting
    # to Hash.  See: https://stackoverflow.com/a/46029524
    allowed_params = %i[account service_id]

    begin
      scope =  authenticators(
        assumed_role(query_role),
        repo = DB::Repository::AuthenticatorRepository.new,
        handler = Authentication::Handler::OidcAuthenticationHandler.new,
        **options(allowed_params)
      )
    rescue ApplicationController::Forbidden
      raise
    rescue ArgumentError => e
      raise ApplicationController::UnprocessableEntity, e.message
    end

    render(json: scope)
  end

  def authenticators(role, repo, handler, account:, service_id: nil)
    unless service_id.present?
      return repo.find_all(
        account: account,
        type: "oidc"
      ).map do |authn|
        {
          name: authn.authenticator_name,
          redirect_url: handler.generate_login_url(authn)
        }
      end
    end

    authn = repo.find(role: role, account: account, type: "oidc", service_id: service_id)
    return {} unless authn

    handler.generate_login_url(authn)
  end

  # The v5 API currently sends +acting_as+ when listing resources
  # for a role other than the current user.
  def query_role
    params[:role].presence || params[:acting_as].presence
  end

  def options(allowed_params)
    params.permit(*allowed_params)
          .slice(*allowed_params).to_h.symbolize_keys
  end

  def index
    authenticators = {
      # Installed authenticator plugins
      installed: installed_authenticators.keys.sort,

      # Authenticator webservices created in policy
      configured:
        Authentication::InstalledAuthenticators.configured_authenticators.sort,

      # Authenticators white-listed in CONJUR_AUTHENTICATORS
      enabled: enabled_authenticators.sort
    }

    render(json: authenticators)
  end

  def status
    Authentication::ValidateStatus.new.(
      authenticator_status_input: status_input,
      enabled_authenticators: Authentication::InstalledAuthenticators.enabled_authenticators_str
    )
    log_audit_success(
      authn_params: status_input,
      audit_event_class: Audit::Event::Authn::ValidateStatus
    )
    render(json: { status: "ok" })
  rescue => e
    log_audit_failure(
      authn_params: status_input,
      audit_event_class: Audit::Event::Authn::ValidateStatus,
      error: e
    )
    log_backtrace(e)
    render(status_failure_response(e))
  end

  def status_input
    @status_input ||= Authentication::AuthenticatorStatusInput.new(
      authenticator_name: params[:authenticator],
      service_id: params[:service_id],
      account: params[:account],
      username: ::Role.username_from_roleid(current_user.role_id),
      client_ip: request.ip
    )
  end

  def authn_jwt_status
    params[:authenticator] = "authn-jwt"
    Authentication::AuthnJwt::ValidateStatus.new.call(
      authenticator_status_input: status_input,
      enabled_authenticators: Authentication::InstalledAuthenticators.enabled_authenticators_str
    )
    render(json: { status: "ok" })
  rescue => e
    log_backtrace(e)
    render(status_failure_response(e))
  end

  def update_config
    Authentication::UpdateAuthenticatorConfig.new.(
      update_config_input: update_config_input
    )
    log_audit_success(
      authn_params: update_config_input,
      audit_event_class: Audit::Event::Authn::UpdateAuthenticatorConfig
    )
    head(:no_content)
  rescue => e
    log_audit_failure(
      authn_params: update_config_input,
      audit_event_class: Audit::Event::Authn::UpdateAuthenticatorConfig,
      error: e
    )
    handle_authentication_error(e)
  end

  def update_config_input
    @update_config_input ||= Authentication::UpdateAuthenticatorConfigInput.new(
      account: params[:account],
      authenticator_name: params[:authenticator],
      service_id: params[:service_id],
      username: ::Role.username_from_roleid(current_user.role_id),
      enabled: Rack::Utils.parse_nested_query(request.body.read)['enabled'] || false,
      client_ip: request.ip
    )
  end

  def login
    result = perform_basic_authn
    raise Unauthorized, "Client not authenticated" unless authentication.authenticated?

    render(plain: result.authentication_key)
  rescue => e
    handle_login_error(e)
  end

  def authenticate_jwt
    params[:authenticator] = "authn-jwt"
    authn_token = Authentication::AuthnJwt::OrchestrateAuthentication.new.call(
      authenticator_input: authenticator_input_without_credentials,
      enabled_authenticators: Authentication::InstalledAuthenticators.enabled_authenticators_str
    )
    render_authn_token(authn_token)
  rescue => e
    handle_authentication_error(e)
  end

  # Update the input to have the username from the token and authenticate
  def authenticate_oidc
    auth_token = Authentication::Handler::OidcAuthenticationHandler.authenticate(
      service_id: params[:service_id],
      account: params[:account],
      parameters: {
        state: params[:state],
        client_ip: request.ip,
        credentials: request.body.read,
        code: params[:code]
      }
    )

    render_authn_token(auth_token)
  rescue => e
    handle_authentication_error(e)
  end

  def authenticate_gcp
    params[:authenticator] = "authn-gcp"
    input = Authentication::AuthnGcp::UpdateAuthenticatorInput.new.(
      authenticator_input: authenticator_input
    )
    # We don't audit success here as the authentication process is not done
  rescue => e
    # At this point authenticator_input.username is always empty (e.g. cucumber:user:USERNAME_MISSING)
    log_audit_failure(
      authn_params: authenticator_input,
      audit_event_class: Audit::Event::Authn::Authenticate,
      error: e
    )
    handle_authentication_error(e)
  else
    authenticate(input)
  end

  def authenticate(input = authenticator_input)
    authn_token = Authentication::Authenticate.new.(
      authenticator_input: input,
      authenticators: installed_authenticators,
      enabled_authenticators: Authentication::InstalledAuthenticators.enabled_authenticators_str
    )
    log_audit_success(
      authn_params: input,
      audit_event_class: Audit::Event::Authn::Authenticate
    )
    render_authn_token(authn_token)
  rescue => e
    log_audit_failure(
      authn_params: input,
      audit_event_class: Audit::Event::Authn::Authenticate,
      error: e
    )
    handle_authentication_error(e)
  end

  def authenticator_input
    @authenticator_input ||= Authentication::AuthenticatorInput.new(
      authenticator_name: params[:authenticator],
      service_id: params[:service_id],
      account: params[:account],
      username: params[:id],
      credentials: request.body.read,
      client_ip: request.ip,
      request: request
    )
  end

  # create authenticator input without reading the request body
  # request body can be relatively large
  # authenticator will read it after basic validation check
  def authenticator_input_without_credentials
    Authentication::AuthenticatorInput.new(
      authenticator_name: params[:authenticator],
      service_id: params[:service_id],
      account: params[:account],
      username: params[:id],
      credentials: nil,
      client_ip: request.ip,
      request: request
    )
  end

  def k8s_inject_client_cert
    # TODO: add this to initializer
    Authentication::AuthnK8s::InjectClientCert.new.(
      conjur_account: ENV['CONJUR_ACCOUNT'],
      service_id: params[:service_id],
      client_ip: request.ip,
      csr: request.body.read,

      # The host-id is split in the client where the suffix is in the CSR
      # and the prefix is in the header. This is done to maintain backwards-compatibility
      host_id_prefix: request.headers["Host-Id-Prefix"]
    )
    head(:accepted)
  rescue => e
    handle_authentication_error(e)
  end

  private

  def render_authn_token(authn_token)
    content_type = :json
    if encoded_response?
      logger.debug(LogMessages::Authentication::EncodedJWTResponse.new)
      content_type = :plain
      authn_token = ::Base64.strict_encode64(authn_token.to_json)
      response.set_header("Content-Encoding", "base64")
    end
    render(content_type => authn_token)
  end

  def log_audit_success(
    authn_params:,
    audit_event_class:
  )
    ::Authentication::LogAuditEvent.new.call(
      authentication_params: authn_params,
      audit_event_class: audit_event_class,
      error: nil
    )
  end

  def log_audit_failure(
    authn_params:,
    audit_event_class:,
    error:
  )
    ::Authentication::LogAuditEvent.new.call(
      authentication_params: authn_params,
      audit_event_class: audit_event_class,
      error: error
    )
  end

  def handle_login_error(err)
    login_error = LogMessages::Authentication::LoginError.new(err.inspect)
    logger.info(login_error)
    log_backtrace(err)

    case err
    when Errors::Authentication::Security::AuthenticatorNotWhitelisted,
      Errors::Authentication::Security::WebserviceNotFound,
      Errors::Authentication::Security::AccountNotDefined,
      Errors::Authentication::Security::RoleNotFound
      raise Unauthorized
    else
      raise err
    end
  end

  def handle_authentication_error(err)
    authentication_error = LogMessages::Authentication::AuthenticationError.new(err.inspect)
    logger.info(authentication_error)
    log_backtrace(err)

    case err
    when Errors::Authentication::Security::RoleNotAuthorizedOnResource
      raise Forbidden

    when Errors::Authentication::RequestBody::MissingRequestParam
      raise BadRequest

    when Errors::Authentication::Jwt::TokenExpired
      raise Unauthorized.new(err.message, true)

    when Errors::Util::ConcurrencyLimitReachedBeforeCacheInitialization
      raise ServiceUnavailable

    when Errors::Authentication::AuthnK8s::CSRMissingCNEntry,
      Errors::Authentication::AuthnK8s::CertMissingCNEntry
      raise ArgumentError

    else
      raise Unauthorized
    end
  end

  def log_backtrace(err)
    err.backtrace.each do |line|
      # We want to print a minimal stack trace in INFO level so that it is easier
      # to understand the issue. To do this, we filter the trace output to only
      # Conjur application code, and not code from the Gem dependencies.
      # We still want to print the full stack trace (including the Gem dependencies
      # code) so we print it in DEBUG level.
      line.include?(ENV['GEM_HOME']) ? logger.debug(line) : logger.info(line)
    end
  end

  def status_failure_response(error)
    logger.debug("Status check failed with error: #{error.inspect}")

    payload = {
      status: "error",
      error: error.inspect
    }

    status_code =
      case error
      when Errors::Authentication::Security::RoleNotAuthorizedOnResource
        :forbidden
      when Errors::Authentication::StatusNotSupported
        :not_implemented
      when Errors::Authentication::AuthenticatorNotSupported
        :not_found
      else
        :internal_server_error
      end

    { json: payload, status: status_code }
  end

  def installed_authenticators
    @installed_authenticators ||= Authentication::InstalledAuthenticators.authenticators(ENV)
  end

  def enabled_authenticators
    Authentication::InstalledAuthenticators.enabled_authenticators
  end

  def encoded_response?
    return false unless request.accept_encoding

    encodings = request.accept_encoding.split(",")
    encodings.any? { |encoding| encoding.squish.casecmp?("base64") }
  end
end
