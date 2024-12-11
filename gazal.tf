# Provider Configuration
provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
}
 
# Data Sources
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}
 
# Variables
variable "aws_region" {
  default = "us-east-1"
}
 
variable "aws_access_key_id" {
  type      = string
  sensitive = false
}
 
variable "aws_secret_access_key" {
  type      = string
  sensitive = false
}
 
variable "ecr_repository_name" {
  default = "dayma-app-repository"
}
 
variable "image_tag" {
  default = "latest"
}
 
variable "vpc_cidr_block" {
  default = "10.0.0.0/16"
}
 
variable "public_subnet_cidr_blocks" {
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}
 
variable "private_subnet_cidr_blocks" {
  default = ["10.0.3.0/24", "10.0.4.0/24"]
}
 
variable "container_port" {
  default = 3000
}
 
variable "cpu" {
  default = 256
}
 
variable "memory" {
  default = 512
}
 
variable "desired_count" {
  default = 1
}
 
variable "environment_variables" {
  type = map(string)
  default = {
    NODE_ENV = "production"
  }
}
 
variable "health_check_path" {
  default = "/"
}
 
# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true
 
  tags = {
    Name = "${var.ecr_repository_name}-vpc"
  }
}
 
# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
 
  tags = {
    Name = "${var.ecr_repository_name}-igw"
  }
}
 
# Public Subnets
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidr_blocks)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr_blocks[count.index]
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[count.index]
 
  tags = {
    Name = "${var.ecr_repository_name}-public-subnet-${count.index + 1}"
  }
}
 
# Private Subnets
resource "aws_subnet" "private" {
  count                   = length(var.private_subnet_cidr_blocks)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr_blocks[count.index]
  map_public_ip_on_launch = false
  availability_zone       = data.aws_availability_zones.available.names[count.index]
 
  tags = {
    Name = "${var.ecr_repository_name}-private-subnet-${count.index + 1}"
  }
}
 
# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
 
  tags = {
    Name = "${var.ecr_repository_name}-public-rt"
  }
}
 
# Route Table Association
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
 
# Route
resource "aws_route" "default_route" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}
 
# Security Groups
resource "aws_security_group" "lb_sg" {
  name        = "${var.ecr_repository_name}-lb-sg"
  description = "Allow inbound HTTP traffic to the load balancer"
  vpc_id      = aws_vpc.main.id
 
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  tags = {
    Name = "${var.ecr_repository_name}-lb-sg"
  }
}
 
resource "aws_security_group" "ecs_sg" {
  name        = "${var.ecr_repository_name}-ecs-sg"
  description = "Allow inbound traffic from the load balancer"
  vpc_id      = aws_vpc.main.id
 
  ingress {
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }
 
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  tags = {
    Name = "${var.ecr_repository_name}-ecs-sg"
  }
}
 
# NAT Gateway
resource "aws_eip" "nat" {
  associate_with_private_ip = true
 
  tags = {
    Name = "${var.ecr_repository_name}-nat-eip"
  }
}
 
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id  # NAT Gateway in the first public subnet
 
  tags = {
    Name = "${var.ecr_repository_name}-nat-gateway"
  }
}
 
# Route Table for Private Subnets
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
 
  tags = {
    Name = "${var.ecr_repository_name}-private-rt"
  }
}
 
# Route for NAT Gateway
resource "aws_route" "private_nat_route" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}
 
# Associate Private Subnets with Private Route Table
resource "aws_route_table_association" "private_subnet" {
  count          = length(var.private_subnet_cidr_blocks)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
 
# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.ecr_repository_name}-ecs-task-execution-role"
 
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}
 
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
 
# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.ecr_repository_name}-cluster"
}
 
# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "/ecs/${var.ecr_repository_name}-dayma-app"
  retention_in_days = 14
}
 
# Application Load Balancer
resource "aws_lb" "app_lb" {
  name               = "${var.ecr_repository_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = aws_subnet.public[*].id
 
  tags = {
    Name = "${var.ecr_repository_name}-alb"
  }
}
 
# Target Group
resource "aws_lb_target_group" "app_tg" {
  name        = "${var.ecr_repository_name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
 
  health_check {
    path                = var.health_check_path
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
  }
 
  tags = {
    Name = "${var.ecr_repository_name}-tg"
  }
}
 
# Listener
resource "aws_lb_listener" "app_lb_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"
 
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}
 
# ECR Repository
resource "aws_ecr_repository" "dayma_app_repo" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true  # This ensures the repository and its images are deleted
}
 
# Null Resource to Build and Push Docker Image
resource "null_resource" "docker_build_and_push" {
  depends_on = [aws_ecr_repository.dayma_app_repo]
 
  provisioner "local-exec" {
    command = format(<<EOF
$password = aws ecr get-login-password --region %s
docker login --gazalaparvin --password $Sparkle@786 %s.dkr.ecr.%s.amazonaws.com
docker build -t dayma-app .
docker tag dayma-app:latest %s.dkr.ecr.%s.amazonaws.com/%s:%s
docker push %s.dkr.ecr.%s.amazonaws.com/%s:%s
EOF
    ,
    var.aws_region,
    data.aws_caller_identity.current.account_id,
    var.aws_region,
    data.aws_caller_identity.current.account_id,
    var.aws_region,
    var.ecr_repository_name,
    var.image_tag,
    data.aws_caller_identity.current.account_id,
    var.aws_region,
    var.ecr_repository_name,
    var.image_tag
    )
 
    interpreter = ["PowerShell", "-Command"]
 
    environment = {
      AWS_ACCESS_KEY_ID     = var.aws_access_key_id
      AWS_SECRET_ACCESS_KEY = var.aws_secret_access_key
      AWS_DEFAULT_REGION    = var.aws_region
    }
  }
}
 
# ECS Task Definition
resource "aws_ecs_task_definition" "app_task" {
  depends_on = [null_resource.docker_build_and_push]  # Ensure image is pushed first
  family                   = "${var.ecr_repository_name}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
 
  container_definitions = jsonencode([
    {
      name      = "dayma-app"
      image     = "${aws_ecr_repository.dayma_app_repo.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_log_group.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "dayma-app"
        }
      }
      environment = [
        for key, value in var.environment_variables : {
          name  = key
          value = value
        }
      ]
    }
  ])
}
 
# ECS Service
resource "aws_ecs_service" "app_service" {
  name            = "${var.ecr_repository_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app_task.arn
  launch_type     = "FARGATE"
  desired_count   = var.desired_count
 
  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }
 
  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "dayma-app"
    container_port   = var.container_port
  }
 
  depends_on = [aws_lb_listener.app_lb_listener]
}
 
# Output the DNS name of the load balancer
output "load_balancer_dns_name" {
  description = "DNS name of the load balancer"
  value       = aws_lb.app_lb.dns_name
}