Feature: Users and Hosts can be CIDR restricted

Users and Hosts can be restricted to only allow authentication
from a particular network, defined by a CIDR in the policy

  Scenario: Loading users and hosts with CIDR restrictions

    Given I load a policy:
    """
    - !user
      id: alice
      restricted_to: 192.168.101.1

    - !user
      id: bob
      restricted_to: 192.168.0.0/16

    - !host
      id: serviceA
      restricted_to: [ 192.168.0.1, 192.168.1.10/32 ]
    """

    When I show the user "alice"
    Then the "restricted_to" should be: 
    """
      ["192.168.101.1/32"]
    """

    When I show the user "bob"
    Then the "restricted_to" should be:
    """
      ["192.168.0.0/16"]
    """ 

    When I show the host "serviceA"
    Then the "restricted_to" should be:
    """
       ["192.168.0.1/32", "192.168.1.10/32"]
    """

  Scenario: Invalid CIDR restriction string

    When I load a policy:
    """
    - !host
      id: serviceA
      restricted_to: an_invalid_cidr_string
    """
    Then there is an error
    And the error code is "validation_failed"
    And the error message includes "Invalid IP address or CIDR range 'an_invalid_cidr_string'"
    

  Scenario: Domain name as CIDR restriction string

    When I load a policy:
    """
    - !host
      id: serviceA
      restricted_to: dap.my-company.net
    """
    Then there is an error
    And the error code is "validation_failed"
    And the error message includes "Invalid IP address or CIDR range 'dap.my-company.net'"

  Scenario: Load policy with invalid CIDR (Bits to the right of the mask)
  Conjur strips the extra bits before storing the CIDR in the database.

    Given I load a policy:
    """
    - !host
      id: serviceA
      restricted_to: 10.0.0.1/24
    """
    Then there is an error
    And the error code is "validation_failed"
    And the error message includes "Invalid IP address or CIDR range '10.0.0.1/24': Value has bits set to right of mask. Did you mean '10.0.0.0/24'"
