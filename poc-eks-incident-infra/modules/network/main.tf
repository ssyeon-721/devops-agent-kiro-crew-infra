locals {
  # AZ 2개만 사용
  azs = ["${var.region}a", "${var.region}c"]
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

# 퍼블릭 서브넷 (NAT용)
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.project}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  }
}

# 프라이빗 서브넷 (Crew EC2 등)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = local.azs[count.index]

  tags = {
    Name                              = "${var.project}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# 워커 노드 서브넷 — 의도적으로 /28 (시나리오 6 IP 고갈)
# /28 = 16 IP - 5 AWS 예약 = 사용 가능 11개
# t3.large 기본 ENI당 12 IP → 노드 2대 × prefix delegation 없이 Pod IP 고갈 유도
resource "aws_subnet" "worker" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.20.${count.index * 16}/28"
  availability_zone = local.azs[count.index]

  tags = {
    Name                              = "${var.project}-worker-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${var.project}-cluster" = "owned"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

# EIP + NAT Gateway (퍼블릭 서브넷 첫 번째)
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.project}-nat" }
  depends_on    = [aws_internet_gateway.main]
}

# 라우팅 — 퍼블릭
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.project}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# 라우팅 — 프라이빗 (Crew + 워커 공용)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "${var.project}-rt-private" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "worker" {
  count          = 2
  subnet_id      = aws_subnet.worker[count.index].id
  route_table_id = aws_route_table.private.id
}
