variable "availability_zone" {
  type        = string
  default     = ""
  description = "Azure Availability Zone for the standalone Anvil. Empty = regional placement."
}
