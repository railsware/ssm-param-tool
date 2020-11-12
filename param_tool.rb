#!/bin/env ruby

require 'yaml'
require 'aws-sdk-ssm'
require 'optparse'

SECURE_MARKER = 'SECURE'
DELETE_MARKER = 'DELETE'

config = {}
OptionParser.new do |opts|
  opts.banner = "Usage: param_tool.rb [options] (down|up)"

  opts.on("-p", "--prefix=PREFIX", "Param prefix") do |p|
    config[:prefix] = p
  end

  opts.on("-k", "--key=KEY", "Encryption key for writing secure params") do |k|
    config[:key] = k
  end

  opts.on("-d", "--dry-run", "Do not apply changes") do
    config[:dryrun] = true
  end
end.parse!
raise OptionParser::MissingArgument, 'prefix' if config[:prefix].nil?

config[:prefix] += '/' if config[:prefix][-1] != '/'
config[:prefix] = "/#{config[:prefix]}" if config[:prefix][0] != '/'

client = Aws::SSM::Client.new

def get_all_params(client, prefix, next_token = nil)
  resp = client.get_parameters_by_path(
    path: prefix,
    recursive: true,
    with_decryption: false,
    next_token: next_token
  )
  params = resp.parameters
  if resp.next_token
    params + get_all_params(client, prefix, resp.next_token)
  else
    params
  end
end

def write_param_tree(client, config, old_param_tree, keypath, value)
  if value.is_a?(Hash)
    value.each do |key, child|
      write_param_tree(client, config, old_param_tree, keypath + [key], child)
    end
  elsif value.is_a?(Array)
    value.each.with_index do |child, index|
      write_param_tree(client, config, old_param_tree, keypath + [index], child)
    end
  else
    key_name = config[:prefix] + keypath.join('/')
    secure = false

    if key_name[-1] == '!'
      key_name = key_name[0..-2]
      secure = true
      if value == SECURE_MARKER
        # skip secure parameter that is not being written
        return
      end
    end

    if value == DELETE_MARKER
      # delete parameter
      puts "Deleting param #{key_name}"

      unless config[:dryrun]
        client.delete_parameter(name: key_name)
      end

      return
    end

    if !secure
      old_value = old_param_tree.dig(*keypath)
      if old_value == value
        # skip params with no change
        return
      end
    end

    puts "Writing new value for #{secure ? 'secure ' : ''}param #{key_name}"

    unless config[:dryrun]
      client.put_parameter(
        name: key_name,
        value: value,
        type: secure ? 'SecureString' : 'String',
        key_id: secure ? config[:key] : nil,
        overwrite: true
      )
    end
  end
end

def read_param_tree(client, config)
  param_tree = {}
  get_all_params(client, config[:prefix]).each do |param|
    name_parts = param.name[config[:prefix].length..-1].split('/')
    key_name = name_parts.pop
    value = param.value
    if param.type == 'SecureString'
      key_name += '!'
      value = SECURE_MARKER
    end
    key_container = name_parts.reduce(param_tree) { |h, k| h[k] ||= {}; h[k] }
    key_container[key_name] = value
  end
  param_tree
end

param_tree = read_param_tree(client, config)

if ARGV[0] == 'down'
  puts YAML.dump(param_tree)
elsif ARGV[0] == 'up'
  new_param_tree = begin
    YAML.load(STDIN.read)
  rescue StandardError => e
    raise "Failed to read params YAML from standard input: #{e}"
  end

  puts "DRY RUN (no changes applied)" if config[:dryrun]

  write_param_tree(client, config, param_tree, [], new_param_tree)
else
  puts "USAGE param_tool.rb (up|down)"
end
