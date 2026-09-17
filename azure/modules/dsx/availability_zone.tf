variable "availability_zone" {
  type        = string
  default     = ""
  description = "Azure Availability Zone for DSX VMs. Empty = regional placement."
}
