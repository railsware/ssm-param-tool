# aws-ecs-tools

A collection of Ruby scripts that make it easier to work with ECS from the command line.

## param_tool.rb

A tool to sync up AWS Systems Manager Parameter Store with a local YAML file.

WIP; TODO a prettier name.

```
Usage: param_tool.rb [options] (down|up)
    -p, --prefix=PREFIX              Param prefix
    -k, --key=KEY                    Encryption key for writing secure params
    -d, --dry-run                    Do not apply changes
```

### Download params

```sh
param_tool.rb --prefix /staging/myapp down >params.yml
```

- secure (encrypted) param values are replaced with `SECURE` - NOT decrypted.
- secure param keys are suffixed with '!'
- param tree is unwrapped into a hash

### Upload params

```sh
param_tool.rb --prefix /staging/myapp up <params.yml

# specify a key to do the encryption:
param_tool.rb --key alias/mailtrap-parameter-store --prefix /staging/myapp up <params.yml

# do a dry run:
param_tool.rb --dry-run --prefix /staging/myapp up <params.yml

```

- params that are not changed will not be updated
- secure params that have a value of `SECURE` are NOT updated
- secure params that have any other value ARE updated - then make sure to provide the proper key
- to make a param secure, add a `!` suffix to the key name - note that the '!' character itself will be stripped from the key name in Parameter Store
- params with a value of `DELETE` are deleted from parameter store

### Workflow concept

- create a YAML file with the params you need; you can reuse the same file for a file-based Global backend.
- upload it to staging
- upload it to prod
- download params from staging, update, and send to prod
- commit param set as reference (make sure that sensitive params are secured, and thus not committed)

### Sample params.yml

```yaml
---
aws:
  bucket: my-bucket
braintree:
  environment: sandbox
  merchant_id!: SECURE
  private_key!: SECURE
  public_key!: SECURE
heroku:
  addon_manifest: |-
    {
     "hey!": "you can do multiline values too",
     "useful": "for SSH keys"
    }
```

## ecs_run.rb

Run shell script or Ruby code on an ECS service

```sh
Usage: ecs_run.rb [options] [command or STDIN]
    -c, --cluster=CLUSTER            Cluster name
    -s, --service=SERVICE            Service name
    -w, --watch                      Watch output
    -r, --ruby                       Run input as Ruby code with Rails runner (instead of shell command)
```

Note that the command is non-interactive - you provide the code and you watch it execute.

### Specify target

Cluster and service are required params. Besides them, you'll need to set the region through environment variables.

### Providing input

There are three ways to provide input:

- as a final argument to the command - make sure to quote it properly

  ```sh
  ecs_run.rb -c app -s app 'rake -T'
  ```

- from a file

  ```sh
  ecs_run.rb -c app -s app <script.sh
  ```

- type it in

  ```sh
  ecs_run.rb -c app -s app
  Type your command then press Ctrl+D
  rake -T
  [Ctrl+D]
  ```

Note that in all cases you're providing literal code to be evaluated on the ECS service; you can't send files; the rest of the environment is defined by the service.

### Watching output

Normally after you start the task you get an AWS Console link to monitor the task online, and that's it.

But if you specify the `--watch` option, you will see the task status changes and the output logged to the terminal. You will also know when the task has finished.

### Running Ruby code

Besides running shell code, you can also run Ruby code with the Rails runner (only available if `bundle` and a Rails app are present in your service's docker image.)

```sh
ecs_run.rb -c app -s app --ruby 'p User.first'
```

This way you get Rails log output, but note that, unlike a Rails console, you don't see command evaluation results by default - you need to print it explicitly.

### Example

```sh
$ ruby ecs_run.rb --cluster myapp --service myapp --watch --ruby
Type your command then press Ctrl+D
Note - Ruby evaluation result is NOT automatically printed, use `p`
User.where("email LIKE '%@myapp.com'").update_all(role: 'admin')
^D
Task started. See it online at https://us-east-1.console.aws.amazon.com/ecs/home?region=us-east-1#/clusters/mailtrap/tasks/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/details
Watching task output. Note - Ctrl+C will stop watching, but will NOT stop the task!
[2020-07-25 08:42:01 +0300] Task status changed to PROVISIONING
[2020-07-25 08:42:23 +0300] Task status changed to PENDING
[2020-07-25 08:43:18 +0300] Task status changed to RUNNING
[2020-07-25 08:43:42 +0300] I, [2020-07-25T05:43:37.853603 #7]  INFO -- : Raven 3.0.0 ready to catch errors
[2020-07-25 08:44:01 +0300] Task status changed to DEPROVISIONING
[2020-07-25 08:44:14 +0300] Task status changed to STOPPED
```
