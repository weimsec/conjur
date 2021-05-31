# frozen_string_literal: true

require 'command_class'
require 'conjur/conjur_config'
require 'open3'

module Commands
  module Configuration
    Apply ||= CommandClass.new(
      dependencies: {
        conjur_config: Conjur::ConjurConfig.new,
        command_runner: Open3,
        process_manager: Process,
        output_stream: $stdout
      },

      inputs: %i[]
    ) do
      def call
        pid = server_pid

        if pid.zero?
          raise 'Conjur is not currently running, please start it with conjurctl server.'
        end

        @process_manager.kill('USR1', pid)

        @output_stream.puts(
          "Conjur server reboot initiated. New configuration will be applied."
        )
      end

      private

      def server_pid
        cmd = "ps -ef | grep puma | grep -v grep | grep -v cluster | " \
              "awk '{print $2}' | tr -d '\n'"
        stdout, _ = @command_runner.capture2(cmd)
        stdout.to_i
      end
    end
  end
end