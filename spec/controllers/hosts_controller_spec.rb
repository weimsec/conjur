require 'spec_helper'

describe HostsController, :type => :request do
  let(:account) { "rspec" }
  let(:user_id) {"#{account}:user:admin"}
  let(:host_name) {"edge-host-6d50922eedee3fa58b8f20f675fc11a3"}
  let(:id) {"edge/#{host_name}/#{host_name}"}
  let(:admins_group) {"Conjur_Cloud_Admins"}
  let(:edge_hosts_group) {"edge/edge-hosts"}

  before do
    init_slosilo_keys(account)
    @current_user = Role.find_or_create(role_id: user_id)
  end

  let(:token_auth_header) do
    bearer_token = user_slosilo_key(account).signed_token(@current_user.login)
    token_auth_str =
      "Token token=\"#{Base64.strict_encode64(bearer_token.to_json)}\""
    { 'HTTP_AUTHORIZATION' => token_auth_str }
  end

  context "Edge-host api" do
    include_context "create host"
    let(:edge_host) { create_host(id) }

    it "User in wrong group (rspec)" do
      # add user to Conjur_Cloud_Admins group
      group_name = "rspec"
      Role.create(role_id: "#{account}:group:#{group_name}")
      RoleMembership.create(role_id: "#{account}:group:#{group_name}", member_id: user_id)
      #add edge-hosts to edge/edge-hosts group
      Role.create(role_id: "#{account}:group:#{edge_hosts_group}")
      RoleMembership.create(role_id: "#{account}:group:#{edge_hosts_group}", member_id: edge_host.role_id)

      get("/edge/edge-hosts/#{account}", env: token_auth_header)
      expect(response.code).to eq("403")
    end
    it "User in wrong group (cucumber)" do
      # add user to Conjur_Cloud_Admins group
      group_name = "cucumber"
      Role.create(role_id: "#{account}:group:#{group_name}")
      RoleMembership.create(role_id: "#{account}:group:#{group_name}", member_id: user_id)
      #add edge-hosts to edge/edge-hosts group
      Role.create(role_id: "#{account}:group:#{edge_hosts_group}")
      RoleMembership.create(role_id: "#{account}:group:#{edge_hosts_group}", member_id: edge_host.role_id)

      get("/edge/edge-hosts/#{account}", env: token_auth_header)
      expect(response.code).to eq("403")
    end
    it "Edge host in wrong group" do
      # add user to Conjur_Cloud_Admins group
      Role.create(role_id: "#{account}:group:#{admins_group}")
      RoleMembership.create(role_id: "#{account}:group:#{admins_group}", member_id: user_id)
      #add edge-hosts to edge/edge-host group
      group_name = "edge/edge-host"
      Role.create(role_id: "#{account}:group:#{group_name}")
      RoleMembership.create(role_id: "#{account}:group:#{group_name}", member_id: edge_host.role_id)

      get("/edge/edge-hosts/#{account}", env: token_auth_header)
      expect(response.code).to eq("200")
      expect(JSON.parse(response.body)).to eq({"hosts"=>[]})
    end
    it "No edge hosts at all" do
      # add user to Conjur_Cloud_Admins group
      Role.create(role_id: "#{account}:group:#{admins_group}")
      RoleMembership.create(role_id: "#{account}:group:#{admins_group}", member_id: user_id)

      get("/edge/edge-hosts/#{account}", env: token_auth_header)
      expect(response.code).to eq("200")
      expect(JSON.parse(response.body)).to eq({"hosts"=>[]})
    end
  end
end