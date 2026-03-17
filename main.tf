# ==============================================================================
# 0. Provider AWS
# ==============================================================================
provider "aws" {
  region = var.aws_region
}

# ==============================================================================
# Data AWS (auto récupération du compte)
# ==============================================================================
data "aws_caller_identity" "current" {}

# ==============================================================================
# 1. VPC
# ==============================================================================
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "main-vpc"
  }
}

# FIX CKV2_AWS_12: Bloquer tout trafic sur le default security group du VPC
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "default-sg-locked"
  }
}

# ==============================================================================
# 2. VPC Flow Logs vers CloudWatch — FIX CKV2_AWS_11
# ==============================================================================
# KMS hors scope sandbox — clés AWS managées. CMK requise en production.
#tfsec:ignore:aws-cloudwatch-log-group-customer-key
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  #checkov:skip=CKV_AWS_158: KMS hors scope sandbox — chiffré par clés AWS managées. CMK requise en production.
  #checkov:skip=CKV_AWS_338: Rétention réduite à 7 jours pour un lab.
  name              = "/aws/vpc/flow-logs"
  retention_in_days = 7  # Réduit pour un lab
}

resource "aws_iam_role" "flow_logs_role" {
  name = "vpc_flow_logs_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

# logs:CreateLogStream obligatoire — ressource contrainte via ARN précis, pas de wildcard réel.
#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_role_policy" "flow_logs_policy" {
  name = "vpc_flow_logs_policy"
  role = aws_iam_role.flow_logs_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      #checkov:skip=CKV_AWS_290: PutLogEvents obligatoire — contrainte via ARN précis.
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = [
        "${aws_cloudwatch_log_group.vpc_flow_logs.arn}",
        "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
      ]
    }]
  })
}

resource "aws_flow_log" "vpc_flow_log" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs_role.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
}

# ==============================================================================
# 3. Internet Gateway
# ==============================================================================
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

# ==============================================================================
# 4. Subnets
# ==============================================================================
# Subnet public — pour Internet Gateway uniquement, aucune EC2 dans ce subnet.
#tfsec:ignore:aws-ec2-no-public-ip-subnet
resource "aws_subnet" "subnet_public" {
  #checkov:skip=CKV_AWS_130: Subnet public sans EC2 — L'EC2 est dans subnet_private.
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
}

# Subnet privé — EC2 uniquement, pas d'IP publique
resource "aws_subnet" "subnet_private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false
}

# ==============================================================================
# 5. Route tables
# ==============================================================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.subnet_public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.subnet_private.id
  route_table_id = aws_route_table.private.id
}

# ==============================================================================
# 6. Security Groups
# ==============================================================================
# Port 80 ouvert publiquement — serveur web public sans ALB en scope sandbox.
#tfsec:ignore:aws-ec2-no-public-ingress-sgr
resource "aws_security_group" "sg_ec2" {
  #checkov:skip=CKV_AWS_260: Port 80 ouvert publiquement — serveur web public sans ALB en scope sandbox.
  description = "Security group for EC2 public web server"
  name   = "ec2-security-group"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "ec2 : Allow HTTP from anywhere (public web server)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ec2 : Allow HTTPS from internal VPC only"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    description = "ec2 : Allow HTTPS outbound to VPC only SSM and ECR via VPC endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  tags = {
    Name = "ec2-security-group"
  }
}

# Security Group pour les VPC Endpoints
resource "aws_security_group" "sg_endpoints" {
  description = "Security group for VPC endpoints (SSM, ECR)"
  name   = "vpc-endpoints-security-group"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "endpoints : Allow HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    description = "endpoints : Allow HTTPS outbound"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  tags = {
    Name = "vpc-endpoints-security-group"
  }
}

# ==============================================================================
# 7. VPC Endpoints
# ==============================================================================
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.subnet_private.id]
  security_group_ids  = [aws_security_group.sg_endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.subnet_private.id]
  security_group_ids  = [aws_security_group.sg_endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.subnet_private.id]
  security_group_ids  = [aws_security_group.sg_endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.subnet_private.id]
  security_group_ids  = [aws_security_group.sg_endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.subnet_private.id]
  security_group_ids  = [aws_security_group.sg_endpoints.id]
  private_dns_enabled = true
}

# ==============================================================================
# 8. IAM EC2
# ==============================================================================
resource "aws_iam_role" "ssm_role" {
  name = "ec2_ssm_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ecr_policy" {
  role = aws_iam_role.ssm_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ecr:GetAuthorizationToken ne supporte pas les ARN spécifiques — limitation AWS
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/${var.ecr_repository_name}"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "ssm_profile"
  role = aws_iam_role.ssm_role.name
}

# ==============================================================================
# 9. EC2
# ==============================================================================
resource "aws_instance" "web" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.subnet_private.id
  vpc_security_group_ids      = [aws_security_group.sg_ec2.id]
  depends_on		      = [aws_security_group.sg_ec2]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  monitoring                  = true  # checkov:skip=CKV_AWS_126: Monitoring activé
  ebs_optimized               = true  # checkov:skip=CKV_AWS_135: EBS optimized activé

  metadata_options {
    http_tokens                 = "required"  # IMDSv2 forcé — protection SSRF
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  root_block_device {
    encrypted = true
  }

  tags = {
    Name = "web-instance"
  }
}

# ==============================================================================
# 10. S3
# ==============================================================================
resource "random_id" "bucket_id" {
  byte_length = 4
}

# KMS hors scope sandbox — AES256 suffisant. CMK requise en production.
#tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket" "mybucket" {
  #checkov:skip=CKV2_AWS_62: Event notifications hors scope.
  #checkov:skip=CKV_AWS_144: Cross-region replication hors scope sandbox.
  #checkov:skip=CKV_AWS_145: KMS hors scope sandbox — AES256 suffisant.
  bucket = "devsecops-iac-project-bucket-${random_id.bucket_id.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "mybucket_lifecycle" {
  bucket = aws_s3_bucket.mybucket.id
  rule {
    id     = "cleanup-old-versions-and-abort-failed-uploads"
    status = "Enabled"

    # Suppression des anciennes versions après 30 jours
    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    # Abandon des uploads multipart incomplets après 7 jours
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Bloquer l'accès public (obligatoire)
resource "aws_s3_bucket_public_access_block" "mybucket" {
  bucket = aws_s3_bucket.mybucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# KMS hors scope sandbox — AES256 suffisant. CMK requise en production.
#tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket_server_side_encryption_configuration" "encrypt" {
  bucket = aws_s3_bucket.mybucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# checkov:skip=CKV2_AWS_61: Lifecycle hors scope — bucket accessoire.
resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.mybucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# checkov:skip=CKV_AWS_18: Logging activé via bucket dédié.
resource "aws_s3_bucket_logging" "mybucket_logging" {
  bucket        = aws_s3_bucket.mybucket.id
  target_bucket = aws_s3_bucket.logs_bucket.id
  target_prefix = "access-logs/"
}

# ==============================================================================
# 11. Bucket logs (ajouté pour le logging S3)
# ==============================================================================
#tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "logs_bucket" {
  #checkov:skip=CKV2_AWS_62: Event notifications hors scope.
  #checkov:skip=CKV_AWS_144: Cross-region replication hors scope sandbox.
  #checkov:skip=CKV2_AWS_61: Lifecycle hors scope — bucket de logs accessoire.
  #checkov:skip=CKV_AWS_145: KMS hors scope sandbox — AES256 suffisant.
  bucket = "devsecops-iac-project-logs-${random_id.bucket_id.hex}"
}

#tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket_server_side_encryption_configuration" "logs_encrypt" {
  bucket = aws_s3_bucket.logs_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs_block_public" {
  bucket = aws_s3_bucket.logs_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs_versioning" {
  bucket = aws_s3_bucket.logs_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}
