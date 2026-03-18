# DevSecOps IaC Project — AWS Infrastructure with Security Pipeline

> Automated, security-hardened AWS infrastructure provisioned with **Terraform**, scanned by **Checkov**, **tfsec** and **Trivy**, deployed via **GitHub Actions CI/CD** and automatically generating a security report.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Tech Stack](#tech-stack)
- [Security Controls](#examples-of-security-controls-checked)
- [CI/CD Pipeline](#cicd-pipeline)
- [Project Structure](#project-structure)
- [Getting Started](#getting-started)
- [Pipeline Jobs](#pipeline-jobs)
- [Security Report](#security-report)
- [DevSecOps Approach](#devsecops-approach)

---

## Overview

This project demonstrates a **DevSecOps** approach to infrastructure-as-code on AWS. Security is integrated at every step of the pipeline — from Terraform code analysis to Docker image scanning and automated deployment — following the principle of **"security as code"**.

Key highlights:
- Infrastructure provisioned entirely with **Terraform** (no manual console clicks)
- **Zero SSH exposure** — EC2 access via AWS SSM Session Manager only
- **Security scans block deployment** if critical vulnerabilities are detected
- EC2 in a **private subnet**, reachable from the internet only through controlled ingress on port 80
- Docker image pulled from **private ECR repository** via VPC endpoints

---

## Architecture

```
Internet
    │
    ▼ (port 80 only)
┌─────────────────────────────────────────────┐
│  VPC  10.0.0.0/16                           │
│                                             │
│  ┌──────────────────┐  ┌─────────────────┐  │
│  │  Public Subnet   │  │  Private Subnet │  │
│  │  10.0.1.0/24     │  │  10.0.2.0/24    │  │
│  │                  │  │                 │  │
│  │  Internet        │  │  ┌───────────┐  │  │
│  │  Gateway ────────┼──┼─▶│  EC2 Web  │  │  │
│  │                  │  │  │  Instance │  │  │
│  └──────────────────┘  │  └─────┬─────┘  │  │
│                        │        │        │  │
│                        │  VPC Endpoints  │  │
│                        │  SSM / ECR / S3 │  │
│                        └─────────────────┘  │
│                                             │
│  Flow Logs → CloudWatch Logs                │
│  Default SG locked                          │
└─────────────────────────────────────────────┘
```

**Key design decisions:**
- EC2 instance lives in the **private subnet** — no public IP
- Internet Gateway is present but routes only to the public subnet
- SSM replaces SSH entirely — no port 22, no key pairs
- VPC Endpoints (SSM, ECR, S3) keep all traffic inside AWS backbone
- VPC Flow Logs capture all network traffic for audit

---

## Tech Stack

| Category | Tool |
|---|---|
| Infrastructure as Code | Terraform |
| Cloud Provider | AWS (eu-north-1) |
| Container Registry | Amazon ECR |
| Secret-free EC2 access | AWS SSM Session Manager |
| IaC Security Scan | Checkov, tfsec |
| Container Security Scan | Trivy |
| CI/CD | GitHub Actions |
| Logging | Amazon CloudWatch |

---

## Examples of security controls checked

### Network
| Control | Status | Detail |
|---|---|---|
| SSH (port 22) blocked | OK | No rule in any security group |
| EC2 in private subnet | OK | `map_public_ip_on_launch = false` |
| Default SG locked | OK | `aws_default_security_group` with no rules |
| VPC Flow Logs enabled | OK | ALL traffic → CloudWatch |
| HTTP restricted | OK | Port 80 inbound only on EC2 SG |
| HTTPS internal only | OK | Port 443 restricted to `10.0.0.0/16` |

### Compute
| Control | Status | Detail |
|---|---|---|
| IMDSv2 enforced | OK | `http_tokens = "required"` — prevents SSRF |
| EBS root volume encrypted | OK | `encrypted = true` |
| Detailed monitoring | OK | `monitoring = true` |
| EBS optimized | OK | `ebs_optimized = true` |
| No public IP | OK | `associate_public_ip_address = false` |

### IAM
| Control | Status | Detail |
|---|---|---|
| Least privilege ECR | OK | Only `BatchGetImage` + `GetDownloadUrlForLayer` on specific repo ARN |
| SSM managed policy | OK | `AmazonSSMManagedInstanceCore` only |

### Storage (S3)
| Control | Status | Detail |
|---|---|---|
| Public access blocked | OK | All 4 block settings enabled |
| Server-side encryption | OK | AES256 (CMK in production) |
| Versioning enabled | OK | Protects against accidental deletion |
| Access logging | OK | Dedicated `logs_bucket` |
| Lifecycle rules | OK | Noncurrent versions purged after 30 days |

---

## CI/CD Pipeline

The GitHub Actions pipeline runs **8 jobs** in sequence. Deployment is gated behind every security scan.

```
push / pull_request to main
         │
         ├──▶ [Job 1] Checkov — IaC Scan (Terraform)
         │
         ├──▶ [Job 2] Checkov — Dockerfile Scan
         │
         ├──▶ [Job 3] tfsec + Security Rules ──────── needs: Job 1
         │
         ├──▶ [Job 4] Trivy — Docker Image Scan ───── needs: Job 1, 2
         │
         ├──▶ [Job 5] Intrusion Tests (nmap) ──────── needs: Jobs 1,2,3,4
         │
         ├──▶ [Job 6] Push to ECR ─────────────────── needs: all above
         │
         ├──▶ [Job 7] Deploy to EC2 via SSM ──────── needs: Job 6
         │
         └──▶ [Job 8] Security Report ─────────────── always runs (if: always())
```

**Deployment is blocked** if any of these fail:
- Checkov detects an unchecked IaC violation
- tfsec finds a HIGH or CRITICAL infrastructure issue
- Trivy finds a CRITICAL or HIGH CVE in the Docker image

---

## Project Structure

```
devsecops-iac-project/
├── .github/
│   └── workflows/
│       └── devsecops-pipeline.yml   # GitHub Actions CI/CD
├── app/
│   └── Dockerfile                   # Application container
├── main.tf                          # All AWS resources
├── variables.tf                     # Input variables
├── terraform.tfvars                 # Variable values (gitignored)
├── outputs.tf                       # Terraform outputs
└── README.md
```

---

## Getting Started

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- AWS CLI configured with appropriate credentials
- Docker (for local image builds)

### Deploy the infrastructure

```bash
# Clone the repository
git clone https://github.com/<your-username>/devsecops-iac-project.git
cd devsecops-iac-project

# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Apply
terraform apply
```

### Required GitHub Secrets

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |

### Required variables (`terraform.tfvars`)

```hcl
aws_region          = "eu-north-1"
aws_account_id      = "<your-account-id>"
ami_id              = "<your-ami-id>"
instance_type       = "t3.micro"
ecr_repository_name = "devsecops-app"
```

---

## Pipeline Jobs

### Job 1 & 2 — Checkov IaC + Dockerfile Scan
Runs [Checkov](https://www.checkov.io/) against Terraform code and the Dockerfile. Any unacknowledged violation causes the pipeline to fail (`soft_fail: false`). Accepted skips are documented inline with justification comments.

### Job 3 — tfsec + Custom Security Rules
Runs [tfsec](https://github.com/aquasecurity/tfsec) at `--minimum-severity HIGH`, then verifies specific rules with bash assertions:
- No SSH port 22 open to `0.0.0.0/0`
- IMDSv2 is required (`http_tokens = required`)
- No public IP on EC2
- EBS root volume is encrypted

### Job 4 — Trivy Image Scan
Builds the Docker image and scans it with [Trivy](https://github.com/aquasecurity/trivy) for `CRITICAL` and `HIGH` CVEs. Exits with code 1 on findings.

### Job 5 — Intrusion Tests
Lightweight port scan with `nmap` to verify no unexpected ports are reachable on the instance.

### Job 6 — Push to ECR
Authenticates to AWS, builds the final image, and pushes it to the private ECR repository. Only runs if all security jobs pass.

### Job 7 — Deploy via SSM
Sends a shell script to the EC2 instance via `aws ssm send-command` (no SSH, no bastion host):
1. Authenticate Docker to ECR
2. Pull the latest image
3. Stop and remove the old container
4. Start the new container on port 80

### Job 8 — Security Report (always runs)
Aggregates all scan results (Checkov, tfsec, Trivy) into a `security-report.md` file, uploaded as a GitHub Actions artifact with 30-day retention.

---

## Security Report

A security report is generated on every pipeline run and stored as a GitHub Actions artifact:

```
security-report-<commit-sha>/
└── security-report.md
```

Contains:
- Run date and commit SHA
- Checkov results for Terraform and Dockerfile
- tfsec output
- Trivy vulnerability table

---

## DevSecOps Approach

This project applies DevSecOps principles across all four phases:

**Plan & Code** — Security requirements defined before writing IaC. Resource-level comments document every accepted risk (`#checkov:skip`, `#tfsec:ignore`) with justification.

**Build** — Checkov and Dockerfile linting run on every commit, blocking merges if violations are found.

**Test** — Trivy scans the built image for known CVEs. Custom bash assertions verify critical security properties of the Terraform code.

**Deploy** — Deployment only occurs after all security gates pass. EC2 access uses SSM — no SSH keys, no exposed port 22, no bastion host.


---

## Author
**Corentin Boutault**

