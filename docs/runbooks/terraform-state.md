# Runbook: Terraform state on SeaweedFS (S3)

Why and what: [ADR 0007](../adr/0007-terraform-state-seaweedfs-s3.md).
Endpoint: `https://s3.home.arpa` (Caddy on `sectools` 443 -> SeaweedFS S3 on 127.0.0.1:8333).
Bucket `tfstate`, key `proxmox/terraform.tfstate`, lock `proxmox/terraform.tfstate.tflock`.

## 1. Create the S3 keys (Mac, once)

The keys never appear on screen or in shell history; they go straight into the AWS CLI's credentials file.

```bash
umask 077
{ echo; echo '[homelab-tfstate]'
  echo "aws_access_key_id = tfstate$(openssl rand -hex 8)"
  echo "aws_secret_access_key = $(openssl rand -hex 32)"; } >> ~/.aws/credentials
chmod 600 ~/.aws/credentials
grep -c '^\[homelab-tfstate\]' ~/.aws/credentials   # expect 1
```

## 2. Deploy SeaweedFS + Caddy on sectools, publish the DNS name

```bash
cd ansible
ansible-playbook playbooks/seaweedfs.yml --limit sectools --check --diff
ansible-playbook playbooks/seaweedfs.yml --limit sectools
ansible-playbook playbooks/dns.yml --limit gateway   # s3.home.arpa is not live until gateway has it
# Once, and again only to change the retention: Object Lock default retention via a short-lived key
ansible-playbook playbooks/seaweedfs.yml --limit sectools -e seaweedfs_set_retention=true
```

Expect `tfstate: {'Mode': 'GOVERNANCE', 'Days': 30}` near the end.

The playbook fetches Caddy's root CA to `ansible/files/ca/sectools-caddy-root.crt` (public cert, committed).

## 3. Check it from the Mac

```bash
dscacheutil -flushcache; sudo killall -HUP mDNSResponder   # drop a cached "no such name"
CA=ansible/files/ca/sectools-caddy-root.crt
aws --profile homelab-tfstate --endpoint-url https://s3.home.arpa --ca-bundle $CA s3 ls s3://tfstate/  # empty, no error
aws --profile homelab-tfstate --endpoint-url https://s3.home.arpa --ca-bundle $CA s3 ls               # shows only tfstate
```

The key must NOT be able to destroy history (all four must fail):

```bash
S3="aws --profile homelab-tfstate --region us-east-1 --endpoint-url https://s3.home.arpa --ca-bundle $CA"
$S3 s3api put-bucket-versioning --bucket tfstate --versioning-configuration Status=Suspended   # InvalidBucketState
$S3 s3api delete-bucket --bucket tfstate                                                         # AccessDenied
$S3 s3api delete-object --bucket tfstate --key <key> --version-id <old id>                       # AccessDenied
$S3 s3api delete-object --bucket tfstate --key <key> --version-id <old id> --bypass-governance-retention  # AccessDenied
```

## 4. Upgrade Terraform and migrate the state

```bash
brew upgrade hashicorp/tap/terraform awscli && terraform version   # needs >= 1.11
cp terraform/proxmox/terraform.tfstate private/terraform.tfstate.pre-s3   # gitignored safety copy
terraform -chdir=terraform/proxmox init -migrate-state         # answer "yes" to copy local -> s3
terraform -chdir=terraform/proxmox plan                        # expect: No changes
```

The first S3 snapshot has serial 1 and a new lineage; the resources are the same. Then remove the local
copies (`.backup` still holds the cloud-init passwords; the bucket is now the source of truth):

```bash
rm -P terraform/proxmox/terraform.tfstate terraform/proxmox/terraform.tfstate.backup terraform/proxmox/tfplan
```

Keep `private/terraform.tfstate.pre-s3` until the first PBS backup of sectools after the migration, then `rm` it
(deleted 2026-10-29). On macOS, `rm -P` and `shred` do not overwrite anything: APFS is copy-on-write and the
SSD remaps blocks. FileVault (on) is what keeps the freed blocks unreadable.

## 5. Prove the lock works

Two overlapping plans (A is slowed down so it holds the lock while B starts):

```bash
TF="terraform -chdir=terraform/proxmox"
($TF plan -parallelism=1 > /tmp/planA.txt 2>&1 &); sleep 2
$TF plan -lock-timeout=0s     # must fail: "Error acquiring the state lock", StatusCode 412, and A's lock info
sleep 15; grep 'No changes' /tmp/planA.txt; $TF plan -lock-timeout=0s   # both succeed
```

(`terraform console` does not hold the lock for its session, so it is no use for this test.)

## Restore an older state version

```bash
S3="aws --profile homelab-tfstate --endpoint-url https://s3.home.arpa --ca-bundle ansible/files/ca/sectools-caddy-root.crt"
$S3 s3api list-object-versions --bucket tfstate --prefix proxmox/terraform.tfstate --query 'Versions[].[VersionId,LastModified,Size]' --output table
$S3 s3api get-object --bucket tfstate --key proxmox/terraform.tfstate --version-id <id> /tmp/old.tfstate
terraform -chdir=terraform/proxmox state push /tmp/old.tfstate    # Terraform refuses an older serial unless -force
rm -P /tmp/old.tfstate
```

## Break-glass: sectools is down

Terraform cannot read state. Restore sectools from PBS first (`scripts/restore-drill.sh` shows the steps).
If you must run Terraform before that: take the latest state from the PBS backup of sectools
(file restore, `/var/lib/seaweedfs` is not a plain file tree, so restore the whole VM to a spare VMID),
or from `private/terraform.tfstate.pre-s3` if it is still recent.
