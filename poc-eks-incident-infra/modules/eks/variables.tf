variable "project"           {}
variable "cluster_version"   {}
variable "vpc_id"            {}
variable "worker_subnet_ids" { type = list(string) }
variable "node_desired_size" { type = number }
variable "node_min_size"     { type = number }
variable "node_max_size"     { type = number }
variable "node_instance_type" {}
