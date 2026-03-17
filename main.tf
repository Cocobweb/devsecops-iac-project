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

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "default-sg-locked"
  }
}

# ============================================================================== 
# 2. CloudWatch + Flow Logs
# ============================================================================== 
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/flow-logs"
  retention_in_days = 365
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

resource "aws_iam_role_policy" "flow_logs_policy" {
  name = "vpc_flow_logs_policy"
  role = aws_iam_role.flow_logs_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
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
resource "aws_subnet" "subnet_public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "subnet_private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false
}

# ============================================================================== 
# 5. Routing
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
# 6. Security Groups (AVANT les VPC Endpoints et EC2)
# ============================================================================== 
# Security Group pour l'instance EC2
resource "aws_security_group" "sg_ec2" {
  name   = "ec2-security-group"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "Allow HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ec2-security-group"
  }
}

# Security Group pour les VPC Endpoints
resource "aws_security_group" "sg_endpoints" {
  name   = "vpc-endpoints-security-group"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "Allow HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    description = "Allow HTTPS outbound"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name

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

resource "aws_s3_bucket" "mybucket" {
  bucket = "devsecops-iac-project-bucket-${random_id.bucket_id.hex}"
  force_destroy = true

  tags = {
    Name = "devsecops-bucket"
  }
}
