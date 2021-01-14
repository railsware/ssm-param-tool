#!/bin/env ruby

require 'yaml'
require 'aws-sdk-ssm'
require 'optparse'

SECURE_MARKER = 'SECURE'
DELETE_MARKER = 'DELETE'

config = {
  yes: false,
  decrypt: false,
  file: nil
}
OptionParser.new do |opts|
  opts.banner = "Usage: param_tool.rb [options] (down|up)"

  opts.on("-f", "--file=FILE", "File with params") do |f|
    config[:file] = f
  end

  opts.on("-p", "--prefix=PREFIX", "Param prefix") do |p|
    config[:prefix] = p
  end

  opts.on("-k", "--key=KEY", "Encryption key for writing secure params (no effect on reading)") do |k|
    config[:key] = k
  end

  opts.on("-d", "--decrypt", "Output decrypted params") do
    config[:decrypt] = true
  end

  opts.on("-y", "--yes", "Apply changes without asking for confirmation (DANGER)") do
    config[:yes] = true
  end
end.parse!
raise OptionParser::MissingArgument, 'prefix' if config[:prefix].nil?

config[:prefix] += '/' if config[:prefix][-1] != '/'
config[:prefix] = "/#{config[:prefix]}" if config[:prefix][0] != '/'

client = Aws::SSM::Client.new

def get_all_params(client, prefix, with_decryption, next_token = nil)
  resp = client.get_parameters_by_path(
    path: prefix,
    recursive: true,
    with_decryption: with_decryption,
    next_token: next_token
  )
  params = resp.parameters
  if resp.next_token
    params + get_all_params(client, prefix, with_decryption, resp.next_token)
  else
    params
  end
end

def build_write_params_plan(client, config, old_param_tree, keypath, value)
  if value.is_a?(Hash)
    value.flat_map do |key, child|
      build_write_params_plan(client, config, old_param_tree, keypath + [key], child)
    end
  elsif value.is_a?(Array)
    value.each.with_index.flat_map do |child, index|
      build_write_params_plan(client, config, old_param_tree, keypath + [index], child)
    end
  else
    secure = false

    if keypath[-1][-1] == '!'
      if value == SECURE_MARKER
        # skip secure parameter that is not being written
        return []
      end

      keypath = keypath.clone.tap { |kp| kp[-1] = kp[-1][0..-2] }
      secure = true
    end

    key_name = config[:prefix] + keypath.join('/')

    if value == DELETE_MARKER
      old_value = old_param_tree.dig(*keypath)
      return [] if old_value.nil?

      return [{ name: key_name, operation: :delete }]
    end

    string_value = value.to_s

    old_value = old_param_tree.dig(*keypath)
    if old_value == string_value
      # skip params with no change
      return []
    end

    [{
      name: key_name,
      operation: old_value ? :update : :create,
      value: string_value,
      secure: secure
    }]
  end
end

def print_write_plan(plan)
  plan.each do |item|
    print "#{item[:operation]} #{item[:name]}"
    if item[:value]
      print ' = '
      if item[:secure]
        print '<sensitive value redacted>'
      else
        print item[:value].inspect
      end
    end

    puts
  end
end

def apply_write_plan(config, client, plan)
  plan.each do |item|
    begin
      if item[:operation] == :delete
        print "deleting parameter #{item[:name]}..."
        begin
          client.delete_parameter(name: key_name)
          puts 'done'
        rescue Aws::SSM::Errors::ParameterNotFound
          puts 'already missing'
        end
      elsif %i[create update].include? item[:operation]
        print "writing parameter #{item[:name]}..."
        client.put_parameter(
          name: item[:name],
          value: item[:value],
          type: item[:secure] ? 'SecureString' : 'String',
          key_id: item[:secure] ? config[:key] : nil,
          overwrite: item[:operation] == :update
        )
        puts 'done'
      end
    rescue Aws::SSM::Errors::ThrottlingException
      puts
      puts 'AWS SSM request limit exceeded - waiting for 1 second before retrying'
      sleep 1
      retry
    end
  end
end

def read_param_tree(client, config, add_secure_suffix = true)
  param_tree = {}
  get_all_params(client, config[:prefix], config[:decrypt]).each do |param|
    name_parts = param.name[config[:prefix].length..-1].split('/')
    key_name = name_parts.pop
    value = param.value
    if param.type == 'SecureString'
      key_name += '!' if add_secure_suffix
      value = SECURE_MARKER unless config[:decrypt]
    end
    key_container = name_parts.reduce(param_tree) { |h, k| h[k] ||= {}; h[k] }
    key_container[key_name] = value
  end
  param_tree
end

if ARGV[0] == 'down'
  yaml_config = YAML.dump(read_param_tree(client, config))
  if config[:file]
    File.open(config[:file], 'w') { |f| f.puts yaml_config }
  else
    $stdout.puts yaml_config
  end
elsif ARGV[0] == 'up'
  config[:decrypt] = true # so we can compare old values to new
  old_param_tree = read_param_tree(client, config, false)
  new_param_tree =
    begin
      if config[:file]
        File.open(config[:file]) { |f| YAML.safe_load(f.read) }
      else
        YAML.safe_load(STDIN.read)
      end
    rescue StandardError => e
      raise "Failed to read params YAML: #{e}"
    end

  plan = build_write_params_plan(client, config, old_param_tree, [], new_param_tree)

  if plan.empty?
    puts 'All parameters are up to date. Nothing to do.'
    exit(0)
  end

  puts 'Planned changes:'

  print_write_plan(plan)

  if !config[:file] && !config[:yes]
    puts 'To automatically apply params from STDIN, run with --yes flag'
    puts 'Operation aborted. No changes were made.'
    exit(1)
  end

  print 'Apply? (anything but "yes" will abort): '
  answer = $stdin.gets.chomp

  if answer != 'yes'
    puts 'Operation aborted. No changes were made.'
    exit(1)
  end

  apply_write_plan(config, client, plan)

  puts 'All done!'
else
  puts "USAGE param_tool.rb (up|down)"
end
