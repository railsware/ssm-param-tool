# ssm-param-tool

A tool to sync up AWS Systems Manager Parameter Store with a local YAML file.

WIP; TODO a prettier name.

```
Usage: param_tool.rb [options] (down|up)
    -p, --prefix=PREFIX              Param prefix
    -k, --key=KEY                    Encryption key for writing secure params
    -d, --dry-run                    Do not apply changes
```

## Download params

```
param_tool.rb --prefix /staging/myapp down >params.yml
```

- secure (encrypted) param values are replaced with `SECURE` - NOT decrypted.
- secure param keys are suffixed with '!'
- param tree is unwrapped into a hash

## Upload params

```
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

## Workflow concept

- create a YAML file with the params you need; you can reuse the same file for a file-based Global backend.
- upload it to staging
- upload it to prod
- download params from staging, update, and send to prod
- commit param set as reference (make sure that sensitive params are secured, and thus not committed)

## Sample params.yml

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
