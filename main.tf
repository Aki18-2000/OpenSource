provider "aws" {
  region = "us-east-1"  # Change to your preferred region
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "public_aki" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_baki" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "privateaki" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = "us-east-1a"
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public_aki" {
  subnet_id      = aws_subnet.public_aki.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_baki" {
  subnet_id      = aws_subnet.public_baki.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  vpc = true
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_aki.id
  depends_on    = [aws_eip.nat]
}

resource "aws_route_table" "privateaki" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}

resource "aws_route_table_association" "privateaki" {
  subnet_id      = aws_subnet.privateaki.id
  route_table_id = aws_route_table.privateaki.id
}

resource "aws_security_group" "allow_ssh_http" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "httpd_instance" {
  ami           = "ami-04b4f1a9cf54c11d0"  # Direct AMI ID
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_aki.id  # Updated to public subnet
  vpc_security_group_ids = [aws_security_group.allow_ssh_http.id]

  user_data = <<-EOF
              #!/bin/bash
              sudo apt-get update
              sudo apt-get install -y docker.io
              sudo systemctl start docker
              sudo systemctl enable docker
              sudo docker run -d -p 80:80 httpd:latest
              EOF

  tags = {
    Name = "HttpdInstanceaki"
  }
}

resource "aws_lb" "new_app_lb" {
  name               = "new-app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_ssh_http.id]
  subnets            = [aws_subnet.public_aki.id, aws_subnet.public_baki.id]

  enable_deletion_protection = false
}

resource "aws_lb_target_group" "new_app_tg" {
  name     = "new-app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_lb_listener" "new_app_lb_listener" {
  load_balancer_arn = aws_lb.new_app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.new_app_tg.arn
  }
}

resource "aws_lb_target_group_attachment" "new_app_tg_attachment" {
  target_group_arn = aws_lb_target_group.new_app_tg.arn
  target_id        = aws_instance.httpd_instance.id
  port             = 80
}
