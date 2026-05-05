# AWS deployment — Phase 1

This directory contains everything needed to launch the TRIBE v2 ViralAnalyser on a single GPU EC2 instance for development and small-scale client demos. The architecture and rationale are described in the conversation; this README is the operational playbook.

## What you get

A single `g6.xlarge` instance (NVIDIA L4, 24GB VRAM) running Ubuntu 22.04 with NVIDIA drivers pre-installed via the AWS Deep Learning AMI (Base GPU). The FastAPI app binds to `127.0.0.1:8000` only — it never listens on a public interface. Access happens through AWS Systems Manager Session Manager port-forwarding, which means there is no inbound port open to the internet, no SSH key to manage, no IP allowlist to maintain. CloudTrail logs every session for free.

A separate 100 GB gp3 EBS volume is attached and mounted at `/workspace`, holding the cloned repo, the Python venv, the TRIBE / Whisper model cache, and runtime media. The volume has `DeletionPolicy: Retain` and `UpdateReplacePolicy: Retain`, so stack tear-downs and updates do not destroy the model cache. If the instance is replaced, you just re-attach the same volume and skip the 5 GB first-run download.

## Prerequisites

The G/VT vCPU quota in your account must be at least 4 (one g6.xlarge has 4 vCPUs). We requested 8 to leave headroom for a g6.2xlarge or a parallel instance during testing. Check status with:

```
aws service-quotas list-requested-service-quota-change-history-by-quota \
  --service-code ec2 --quota-code L-DB2E81BA --region ap-south-1 \
  --query 'RequestedQuotas[0].[Status,DesiredValue]' --output text
```

The local `session-manager-plugin` is required for port-forwarding. Verify with `which session-manager-plugin`. On macOS, `brew install --cask session-manager-plugin`.

## Deploy

The CloudFormation template needs a VPC and a public subnet. The default VPC works fine. The one-liner that pulls those values and deploys:

```
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region ap-south-1)
SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC \
  Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' \
  --output text --region ap-south-1)

aws cloudformation deploy \
  --stack-name tribe-viralanalyser-phase1 \
  --template-file deploy/aws/cfn-phase1.yaml \
  --capabilities CAPABILITY_IAM \
  --region ap-south-1 \
  --parameter-overrides VpcId=$VPC SubnetId=$SUBNET
```

CloudFormation creates the IAM role, security group, EBS volume, and instance in that order. Total wall time is roughly 5 minutes for the AWS resources, plus another 10–15 minutes for the user-data script to install dependencies and pre-pull the TRIBE and Whisper model checkpoints.

## Watch the bootstrap

The instance writes user-data progress to `/var/log/cfn-userdata.log` and the heavier bootstrap script writes to `/var/log/bootstrap.log`. Open a session and tail them:

```
INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name tribe-viralanalyser-phase1 --region ap-south-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
  --output text)

aws ssm start-session --target $INSTANCE_ID --region ap-south-1
# inside the session:
sudo tail -f /var/log/bootstrap.log
```

When the bootstrap is complete you will see `[bootstrap] complete; service status:` followed by an `active (running)` line for `viralanalyser.service`.

## Open the app

Once `viralanalyser.service` is active, tunnel a local port to the FastAPI server. The CloudFormation stack output `SSMPortForward` contains the exact command; you can also run it directly:

```
aws ssm start-session --target $INSTANCE_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters 'portNumber=["8000"],localPortNumber=["8000"]' \
  --region ap-south-1
```

Open `http://localhost:8000` in your browser. Traffic tunnels through SSM to the instance's loopback interface; nothing is ever exposed publicly.

## Common operations

Restart the FastAPI service after editing the code:

```
aws ssm start-session --target $INSTANCE_ID --region ap-south-1
# inside:
cd /workspace/app && sudo -u ubuntu git pull
sudo systemctl restart viralanalyser
journalctl -u viralanalyser -f
```

Verify GPU is being used during a request — open one session running `watch -n1 nvidia-smi` while a request is being processed in another.

Snapshot the data volume before any risky change:

```
VOL=$(aws ec2 describe-volumes --filters Name=tag:Name,Values=tribe-data \
  --query 'Volumes[0].VolumeId' --output text --region ap-south-1)
aws ec2 create-snapshot --volume-id $VOL \
  --description "tribe-data pre-change $(date -u +%Y%m%d-%H%M)" \
  --region ap-south-1
```

Stop the instance to pause billing for compute (you still pay for EBS, ~$10/month for 100 GB gp3):

```
aws ec2 stop-instances --instance-ids $INSTANCE_ID --region ap-south-1
```

Start it again when you need it. The instance is configured with `nofail` mounts and idempotent bootstrap, so a stop/start is safe.

## Tear down

```
aws cloudformation delete-stack --stack-name tribe-viralanalyser-phase1 --region ap-south-1
```

Because the data volume has `DeletionPolicy: Retain`, the stack delete leaves it behind. Find and delete it manually if you truly want everything gone:

```
aws ec2 describe-volumes --filters Name=tag:Project,Values=TRIBE-ViralAnalyser \
  --query 'Volumes[].VolumeId' --output text --region ap-south-1
aws ec2 delete-volume --volume-id vol-xxxxx --region ap-south-1
```

## Activating the Project cost-allocation tag

Cost allocation tags need a one-time activation in AWS Console before a budget can filter on them. The activation only becomes possible after AWS Cost Explorer discovers a tag in actual billing data, which happens roughly 24–48 hours after the first resource is tagged. Our CloudFormation template tags every resource with `Project: TRIBE-ViralAnalyser`, so the discovery starts as soon as the stack deploys.

Once the stack has been running for a day or two, sign in to the AWS Console, open Billing and Cost Management, then Cost allocation tags, then the User-defined cost allocation tags tab. Find `Project` in the list, select the row, and click Activate. After activation, AWS takes another ~24 hours to start emitting tag-attributed cost data into Cost Explorer.

Once the tag is active and reporting, we can tighten the budget filter to attribute every TRIBE resource (compute, EBS, data transfer, all of it) instead of just the GPU compute hour the current `UsageType` filter catches. The CLI replacement for the budget at that point would add `"TagKeyValue": ["user:Project$TRIBE-ViralAnalyser"]` to `CostFilters`. Until then, the GPU-shape filter we have in place catches roughly 90% of TRIBE spend (compute is by far the dominant line item) and excludes your existing Mumbai infrastructure cleanly because none of those instances are GPU shapes.

## What changes for client access (Phase 2)

Phase 2 adds Cloudflare Tunnel + Cloudflare Access for a free authenticated public URL. The instance still binds the FastAPI server to `127.0.0.1`; `cloudflared` runs as a second systemd unit, registers a tunnel, and forwards a `*.cfargotunnel.com` subdomain through to the loopback. Cloudflare Access enforces email-OTP or Google/Microsoft SSO before any request reaches the tunnel. Setup is documented separately once Phase 1 is verified working.

## Troubleshooting

If `cloudformation deploy` fails with `VcpuLimitExceeded`, the quota request has not yet been approved. Check status with the command in Prerequisites. Re-run deploy once approved.

If the bootstrap log shows `no chromium binary found`, Ubuntu 22.04's `chromium-browser` package is unavailable in some regions. The fallback is to install via snap (`snap install chromium`) and adjust `TRIBE_CHROME_PATH` in `/etc/viralanalyser.env`.

If TRIBE inference falls to CPU despite running on a GPU instance, check `nvidia-smi` and `python -c 'import torch; print(torch.cuda.is_available())'` from inside the venv. The DLAMI driver and the torch wheel must match — if you change torch versions, also update the `--extra-index-url` in `bootstrap.sh` to the matching `cu12X` channel.

If the FastAPI service won't start after a code update, `journalctl -u viralanalyser -n 100` will show the Python traceback. The most common cause is an import error from a new dependency added to `requirements.txt` without re-running `pip install -r requirements.txt` inside the venv.
