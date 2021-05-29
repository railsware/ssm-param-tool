#!/bin/env ruby

require 'aws-sdk-ecs'
require 'aws-sdk-cloudwatchlogs'
require 'optparse'
require 'shellwords'

config = {}
OptionParser.new do |opts|
  opts.banner = 'Usage: ecs_run.rb [options] [command or STDIN]'

  opts.on('-c', '--cluster=CLUSTER', 'Cluster name') do |c|
    config[:cluster] = c
  end

  opts.on('-s', '--service=SERVICE', 'Service name') do |s|
    config[:service] = s
  end

  opts.on('-C', '--container=CONTAINER', 'Container name') do |s|
    config[:container] = s
  end

  opts.on('-w', '--watch', 'Watch output') do |s|
    config[:watch] = true
  end

  opts.on('-r', '--ruby', 'Run input as Ruby code with Rails runner (instead of shell command)') do |r|
    config[:ruby] = true
  end

  opts.on('-R', '--region=REGION', 'Aws region') do |r|
    config[:region] = r
  end

  opts.on('-C', '--container=CONTAINER', 'Container name') do |c|
    config[:container] = c
  end
end.parse!
raise OptionParser::MissingArgument, 'cluster' if config[:cluster].nil?
raise OptionParser::MissingArgument, 'service' if config[:service].nil?

command = ARGV[0]
unless command
  puts 'Type your command then press Ctrl+D' if STDIN.tty?
  puts 'Note - Ruby evaluation result is NOT automatically printed, use `p`' if config[:ruby]
  puts
  command = STDIN.read
  puts
end
command = "bundle exec rails runner #{command.shellescape}" if config[:ruby]

client_opts = {}
client_opts[:region] = config[:region] if config[:region]
client = Aws::ECS::Client.new(client_opts)
unless client_opts[:region]
  puts "No region is specified. Using #{client.config.region}"
end

resp = client.describe_services(
  cluster: config[:cluster],
  services: [
    config[:service]
  ]
)
service = resp.services[0]

task_definition = client.describe_task_definition(task_definition: service.task_definition).task_definition

container_name = if config[:container]
  task_definition.container_definitions.detect { |cd| cd.name == config[:container] }&.name
else
  first_container_name = task_definition.container_definitions.first.name
  if task_definition.container_definitions.length > 1
    puts "Container not set in options. Taking first: #{first_container_name} " \
      "out of #{task_definition.container_definitions.map(&:name).join(', ')}."
  end
  first_container_name
end

raise 'No container found.' unless container_name

vpc_config = service.deployments[0].network_configuration.awsvpc_configuration

subnet = vpc_config.subnets[0]
security_group = vpc_config.security_groups[0]

task_response = client.run_task(
  cluster: config[:cluster],
  task_definition: service.task_definition,
  launch_type: 'FARGATE',
  overrides: {
    container_overrides: [
      {
        name: container_name,
        command: ['sh', '-c', command]
      }
    ]
  },
  network_configuration: {
    awsvpc_configuration: {
      subnets: [subnet],
      security_groups: [security_group],
      assign_public_ip: 'ENABLED'
    }
  }
)

task_arn = task_response.tasks[0].task_arn
task_arn_parts = task_arn.split(':')
task_region = task_arn_parts[3]
task_id = task_arn_parts[5].split('/').last

puts "Task started. See it online at https://#{task_region}.console.aws.amazon.com/ecs/home?region=#{task_region}#/clusters/#{config[:cluster]}/tasks/#{task_id}/details"

exit unless config[:watch]

puts 'Watching task. Note - Ctrl+C will stop watching, but will NOT stop the task!'
last_notified_status = ''

log_configuration = task_definition.container_definitions.first.log_configuration
log_client = nil
log_stream_name = nil
log_token = nil
if log_configuration.log_driver == 'awslogs'
  log_client = Aws::CloudWatchLogs::Client.new
  log_stream_name = "#{log_configuration.options['awslogs-stream-prefix']}/#{container_name}/#{task_id}"
  log_token = nil
else
  puts 'Use `awslogs` log adapter to see the task output.'
end

loop do
  task_status = client.describe_tasks(cluster: config[:cluster], tasks: [task_id]).tasks[0].last_status
  if task_status != last_notified_status
    puts "[#{Time.now}] Task status changed to #{task_status}"
    last_notified_status = task_status
    break if task_status == 'STOPPED'
  end

  if log_client && %w[RUNNING DEPROVISIONING].include?(task_status)
    begin
      events_resp = log_client.get_log_events(
        log_group_name: log_configuration.options['awslogs-group'],
        log_stream_name: log_stream_name,
        start_from_head: true,
        next_token: log_token
      )
      events_resp.events.each do |event|
        puts "[#{Time.at(event.timestamp / 1000)}] #{event.message}"
      end
      log_token = events_resp.next_forward_token
    rescue Aws::CloudWatchLogs::Errors::ResourceNotFoundException
      # task did not output anything to the logs yet
    end
  end
  sleep 1
end
