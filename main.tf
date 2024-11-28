# AWS Provider Configuration
provider "aws" {
  region = "us-east-1"
}

# VPC
resource "aws_vpc" "example" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "example-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "example" {
  vpc_id = aws_vpc.example.id
  tags = {
    Name = "example-internet-gateway"
  }
}

# Subnet
resource "aws_subnet" "example" {
  vpc_id                  = aws_vpc.example.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"
  tags = {
    Name = "example-subnet"
  }
}

# Route Table
resource "aws_route_table" "example" {
  vpc_id = aws_vpc.example.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.example.id
  }
  tags = {
    Name = "example-route-table"
  }
}

# Associate Route Table to Subnet
resource "aws_route_table_association" "example" {
  subnet_id      = aws_subnet.example.id
  route_table_id = aws_route_table.example.id
}

# Security Group
resource "aws_security_group" "allow_ssh" {
  name        = "allow-ssh"
  description = "Allow SSH traffic from anywhere"
  vpc_id      = aws_vpc.example.id

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow-ssh"
  }
}

# IAM Role for EC2
resource "aws_iam_role" "example" {
  name = "example-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# CloudWatch Agent Policy
resource "aws_iam_policy" "cloudwatch_agent_policy" {
  name        = "example-cloudwatch-agent-policy"
  description = "Allow EC2 instances to write to CloudWatch"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["cloudwatch:*", "logs:*", "ssm:*", "autoscaling:*"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.example.name
  policy_arn = aws_iam_policy.cloudwatch_agent_policy.arn
}

resource "aws_iam_instance_profile" "example" {
  name = "example-instance-profile"
  role = aws_iam_role.example.name
}

# Key Pair
resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "example" {
  key_name   = "example-key-pair"
  public_key = tls_private_key.example.public_key_openssh
}

resource "local_file" "private_key" {
  content          = tls_private_key.example.private_key_pem
  filename         = "${path.module}/example-key-pair.pem"
  file_permission  = "0400"
}

# Launch Template
resource "aws_launch_template" "example" {
  name          = "example-launch-template"
  instance_type = "t2.micro"
  image_id      = "ami-0453ec754f44f9a4a"
  key_name      = aws_key_pair.example.key_name
  iam_instance_profile {
    name = aws_iam_instance_profile.example.name
  }
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.allow_ssh.id]
  }
  user_data = base64encode(<<EOT
#!/bin/bash
set -e
yum update -y
yum install -y amazon-cloudwatch-agent
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc/
PARAMETER_NAME="/reparser-uat/autoscaling/config"
PARAMETER_VALUE=$(aws ssm get-parameter --name "$PARAMETER_NAME" --query "Parameter.Value" --output text)
echo "$PARAMETER_VALUE" > /tmp/amazon-cloudwatch-agent.json
sudo cp /tmp/amazon-cloudwatch-agent.json /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
sudo service amazon-cloudwatch-agent start
EOT
  )
}

# SSM Parameter
resource "aws_ssm_parameter" "asg_config" {
  name        = "/reparser-uat/autoscaling/config"
  type        = "String"
  value       = jsonencode({ agent = { metrics_collection_interval = 30 } })
  description = "Auto Scaling Group and EC2 Metrics Configuration"
}

# Auto Scaling Group
resource "aws_autoscaling_group" "example" {
  name                 = "example-asg"
  launch_template {
    id      = aws_launch_template.example.id
    version = "$Latest"
  }
  vpc_zone_identifier = [aws_subnet.example.id]
  min_size            = 2
  max_size            = 20
  desired_capacity    = 2
  tag {
    key                 = "Name"
    value               = "example-instance"
    propagate_at_launch = true
  }
}

# Scaling Policies
resource "aws_autoscaling_policy" "scale_up" {
  name                   = "scale-up"
  policy_type            = "SimpleScaling"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.example.name
}

resource "aws_autoscaling_policy" "scale_down" {
  name                   = "scale-down"
  policy_type            = "SimpleScaling"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.example.name
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "MemoryUtilization"
  namespace           = "EC2_ASG_Memory"
  period              = 60
  statistic           = "Average"
  threshold           = 10
  alarm_actions       = [aws_autoscaling_policy.scale_up.arn]
  actions_enabled     = true
  unit                = "Percent"
}

resource "aws_cloudwatch_metric_alarm" "memory_low" {
  alarm_name          = "memory-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "MemoryUtilization"
  namespace           = "EC2_ASG_Memory"
  period              = 60
  statistic           = "Average"
  threshold           = 5
  alarm_actions       = [aws_autoscaling_policy.scale_down.arn]
  actions_enabled     = true
  unit                = "Percent"
}
