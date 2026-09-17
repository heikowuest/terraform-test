# ============================================================
# Hammerspace Anvil + DSX on Azure - Terraform port of the
# Azure Marketplace ARM template (mainTemplate), structured
# like the AWS root: pre-flight -> NSG -> Anvil -> DSX -> tag.
#
# deployment_mode: standalone | ha | dsx.
# HA uses availability sets; standalone / DSX deployments can
# optionally use an Availability Zone via availability_zone.
#
# Dry run: `terraform plan` runs every input validation and the
# pre-flight without creating anything.
# ============================================================

# --- Resource group: existing by default, created on request ---
resource "azurerm_resource_group" "this" {
  count = var.create_resource_group ? 1 : 0

  name     = var.resource_group
  location = var.location
  tags     = local.tags
}

data "azurerm_resource_group" "this" {
  count = var.create_resource_group ? 0 : 1

  name = var.resource_group
}

locals {
  # Referencing this local (not var.resource_group) gives every resource an
  # implicit dependency on the created group.
  resource_group = var.create_resource_group ? one(azurerm_resource_group.this[*].name) : one(data.azurerm_resource_group.this[*].name)
}

data "azurerm_subnet" "data" {
  name                 = var.data_subnet_name
  virtual_network_name = var.virtual_network_name
  resource_group_name  = local.vnet_resource_group
}

# Only looked up when a dedicated heartbeat subnet is requested (legacy
# dual-NIC layout) - HA works on the data subnet alone by default.
data "azurerm_subnet" "ha" {
  count = local.is_ha && var.ha_subnet_name != "" ? 1 : 0

  name                 = var.ha_subnet_name
  virtual_network_name = var.virtual_network_name
  resource_group_name  = local.vnet_resource_group
}

# --- Pre-flight: hard-stops the plan before any resource is created ---
module "preflight" {
  count  = var.skip_preflight ? 0 : 1
  source = "./modules/preflight"

  mode         = var.deployment_mode
  location     = local.location
  subscription = var.subscription_id
  vm_sizes     = local.is_dsx_only ? [var.dsx_instance_type] : [var.anvil_instance_type, var.dsx_instance_type]
  premium_sizes = compact([
    contains(["Premium_LRS", "PremiumV2_LRS", "UltraSSD_LRS"], local.anvil_os_storage_type) || contains(["Premium_LRS", "PremiumV2_LRS", "UltraSSD_LRS"], local.anvil_meta_storage_type) ? var.anvil_instance_type : "",
    contains(["Premium_LRS", "PremiumV2_LRS", "UltraSSD_LRS"], local.dsx_os_storage_type) || contains(["Premium_LRS", "PremiumV2_LRS", "UltraSSD_LRS"], local.dsx_data_storage_type) ? var.dsx_instance_type : "",
  ])
  # Product minimums (hard pre-flight stops): Anvil 16 vCPU / 32 GiB,
  # DSX 8 vCPU / 16 GiB.
  anvil_size       = local.is_dsx_only ? "" : var.anvil_instance_type
  anvil_min_vcpus  = 16
  anvil_min_mem_gb = 32
  dsx_size         = var.dsx_count > 0 ? var.dsx_instance_type : ""
  dsx_min_vcpus    = 8
  dsx_min_mem_gb   = 16
  image_id         = var.image_id
  image_sas_url    = var.image_sas_url
  check_anvil      = local.is_dsx_only
  anvil_ip         = var.anvil_ip
  anvil_password   = var.admin_password
  hsuser           = var.hsuser
}

# PremiumV2/Ultra disks cannot live on availability-set VMs - HA metadata and
# non-zonal DSX data disks fall back to Premium_LRS. Surfaced as a plan warning
# so the fallback is never silent.
check "perf_disk_fallback" {
  assert {
    condition     = !local.anvil_meta_fallback
    error_message = "anvil_metadata_disk_type ${local.anvil_meta_requested} is not supported on availability-set VMs (HA) - falling back to Premium_LRS. For 5000 IOPS on Premium_LRS use anvil_metadata_disk_size = 1024."
  }
  assert {
    condition     = !(var.dsx_count > 0 && local.dsx_data_fallback)
    error_message = "dsx_data_disk_type ${local.dsx_data_requested} is not supported on availability-set VMs - falling back to Premium_LRS for the DSX data disks."
  }
}

check "preflight_warnings" {
  assert {
    condition     = var.skip_preflight || try(module.preflight[0].warnings, "") == ""
    error_message = "PRE-FLIGHT WARNING(S):\n${try(module.preflight[0].warnings, "")}"
  }
}

# --- Optional: build the boot image from a customer-delivered VHD SAS URL ---
# Stages the .vhd (server-side copy) into a storage account and wraps it in a
# managed image the VMs boot from. CREATE-ONLY: destroy keeps the image so
# apply/destroy cycles of the product never re-download - the idempotent
# staging script no-ops when the image exists. With create_resource_group,
# set image_resource_group (script auto-creates it) so the image lives
# outside the group that destroy deletes.
module "image_from_sas" {
  count  = var.image_sas_url != "" ? 1 : 0
  source = "./modules/image-from-vhd"

  location       = local.location
  resource_group = var.image_resource_group != "" ? var.image_resource_group : local.resource_group
  sas_url        = var.image_sas_url
  tags           = local.tags

  depends_on = [terraform_data.validate_inputs, module.preflight]
}

locals {
  # The image the VMs actually boot from: staged-from-SAS image when
  # image_sas_url is set, otherwise the caller-supplied image_id
  # (marketplace_image bypasses both).
  image_id_effective = var.image_sas_url != "" ? one(module.image_from_sas[*].image_id) : var.image_id
}

# --- Network security group (ARM: <prefix>NetSecGroup) ---
# One Allow rule (priority 2000) with the Hammerspace port set - the Azure
# reference is port-scoped, unlike the AWS playbooks' wide-open placeholder.
# Attached per-NIC (the existing subnet keeps its own NSG untouched).
resource "azurerm_network_security_group" "this" {
  count = var.network_security_group_id == "" ? 1 : 0

  name                = "${local.prefix}NetSecGroup"
  location            = local.location
  resource_group_name = local.resource_group
  tags                = local.tags

  security_rule {
    name                       = "${local.prefix}NetSecGroup-rule-in-2000"
    priority                   = 2000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    destination_port_ranges    = local.nsg_ports
  }

  depends_on = [terraform_data.validate_inputs]
}

# --- Boot diagnostics (serial console/boot log for every VM) ---
resource "azurerm_storage_account" "diag" {
  count = var.boot_diagnostics ? 1 : 0

  # Prefix in the hash: multiple deployments (e.g. a dsx add) share a
  # resource group, and each needs its own diagnostics account.
  name                     = "hsdiag${substr(sha1("${local.resource_group}-${local.location}-${local.prefix}"), 0, 16)}"
  resource_group_name      = local.resource_group
  location                 = local.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = local.tags
}

locals {
  diag_storage_uri = var.boot_diagnostics ? one(azurerm_storage_account.diag[*].primary_blob_endpoint) : ""
}

# --- Placement (ARM: PPG + availability sets, fault domain count 2) ---
resource "azurerm_proximity_placement_group" "this" {
  count = var.use_proximity_placement_group && var.proximity_placement_group_name == "" ? 1 : 0

  name                = "${local.prefix}PPG"
  location            = local.location
  resource_group_name = local.resource_group
  tags                = local.tags
}

data "azurerm_proximity_placement_group" "existing" {
  count = var.use_proximity_placement_group && var.proximity_placement_group_name != "" ? 1 : 0

  name                = var.proximity_placement_group_name
  resource_group_name = local.resource_group
}

resource "azurerm_availability_set" "anvil" {
  count = local.is_ha && var.availability_set_name == "" ? 1 : 0

  name                         = "${local.prefix}AnvilAvailSet"
  location                     = local.location
  resource_group_name          = local.resource_group
  platform_fault_domain_count  = 2
  managed                      = true
  proximity_placement_group_id = local.ppg_id
  tags                         = local.tags
}

resource "azurerm_availability_set" "dsx" {
  count = var.dsx_count > 0 && var.availability_zone == "" && var.availability_set_name == "" ? 1 : 0

  name                         = "${local.prefix}DSXAvailSet"
  location                     = local.location
  resource_group_name          = local.resource_group
  platform_fault_domain_count  = 2
  managed                      = true
  proximity_placement_group_id = local.ppg_id
  tags                         = local.tags
}

data "azurerm_availability_set" "existing" {
  count = var.availability_set_name != "" && var.availability_zone == "" ? 1 : 0

  name                = var.availability_set_name
  resource_group_name = local.resource_group
}

# --- Anvil ---
module "anvil_standalone" {
  count  = local.is_standalone ? 1 : 0
  source = "./modules/anvil-standalone"

  prefix                   = local.prefix
  location                 = local.location
  resource_group           = local.resource_group
  data_subnet_id           = data.azurerm_subnet.data.id
  nsg_id                   = local.nsg_id
  image_id                 = local.image_id_effective
  marketplace_image        = var.marketplace_image
  instance_type            = var.anvil_instance_type
  boot_disk_size           = var.anvil_boot_disk_size
  boot_disk_type           = local.anvil_os_storage_type
  metadata_disk_size       = var.anvil_metadata_disk_size
  metadata_disk_type       = local.anvil_meta_storage_type
  metadata_disk_iops       = var.anvil_metadata_disk_iops
  metadata_disk_throughput = var.anvil_metadata_disk_throughput
  static_ip                = var.anvil_data_cluster_ip
  public_ip                = var.public_ip_addresses
  availability_set_id      = local.anvil_avail_set_id
  availability_zone        = var.availability_zone
  ppg_id                   = local.ppg_id
  admin_username           = local.admin_username
  admin_password           = var.admin_password
  domain                   = local.domain
  diag_storage_uri         = local.diag_storage_uri
  tags                     = local.tags

  depends_on = [terraform_data.validate_inputs, module.preflight]
}

module "anvil_ha" {
  count  = local.is_ha ? 1 : 0
  source = "./modules/anvil-ha"

  prefix              = local.prefix
  location            = local.location
  resource_group      = local.resource_group
  data_subnet_id      = data.azurerm_subnet.data.id
  ha_subnet_id        = one(data.azurerm_subnet.ha[*].id)
  node_ips            = var.anvil_node_ips
  subnet_prefixlen    = local.data_subnet_prefixlen
  nsg_id              = local.nsg_id
  image_id            = local.image_id_effective
  marketplace_image   = var.marketplace_image
  instance_type       = var.anvil_instance_type
  boot_disk_size      = var.anvil_boot_disk_size
  boot_disk_type      = local.anvil_os_storage_type
  metadata_disk_size  = var.anvil_metadata_disk_size
  metadata_disk_type  = local.anvil_meta_storage_type
  cluster_ip          = var.anvil_data_cluster_ip
  public_ip           = var.public_ip_addresses
  availability_set_id = local.anvil_avail_set_id
  ppg_id              = local.ppg_id
  admin_username      = local.admin_username
  admin_password      = var.admin_password
  domain              = local.domain
  diag_storage_uri    = local.diag_storage_uri
  tags                = local.tags

  depends_on = [terraform_data.validate_inputs, module.preflight]
}

# --- DSX node(s) ---
# Created in PARALLEL with the Anvil VMs (deliberate deviation from the ARM
# template's dependsOn): the DSX only needs the cluster IP in its custom
# data - known once the Anvil NIC (standalone) or LB frontend (ha) exists -
# and its first boot simply retries the join until the Anvil is ready.
module "dsx" {
  count  = var.dsx_count > 0 ? 1 : 0
  source = "./modules/dsx"

  node_count          = var.dsx_count
  prefix              = local.prefix
  location            = local.location
  resource_group      = local.resource_group
  data_subnet_id      = data.azurerm_subnet.data.id
  nsg_id              = local.nsg_id
  image_id            = local.image_id_effective
  marketplace_image   = var.marketplace_image
  instance_type       = var.dsx_instance_type
  boot_disk_size      = var.dsx_boot_disk_size
  boot_disk_type      = local.dsx_os_storage_type
  data_disk_count     = var.dsx_data_disk_count
  data_disk_size      = var.dsx_data_disk_size
  data_disk_type      = local.dsx_data_storage_type
  data_disk_striping  = var.dsx_data_disk_striping
  metadata_ip         = local.anvil_ip
  subnet_prefixlen    = local.data_subnet_prefixlen
  public_ip           = var.public_ip_addresses
  static_ips          = var.dsx_static_ips
  availability_set_id = local.dsx_avail_set_id
  availability_zone   = var.availability_zone
  ppg_id              = local.ppg_id
  admin_username      = local.admin_username
  admin_password      = var.admin_password
  domain              = local.domain
  diag_storage_uri    = local.diag_storage_uri
  tags                = local.tags

  depends_on = [terraform_data.validate_inputs, module.preflight]
}

# --- Wait for the cluster API, then tag every VM with the cluster ID ---
# Same aws_tag_cluster_id equivalent as on AWS; the tagging command is the
# only cloud-specific part (az tag update per VM).
module "cluster_tag" {
  count  = var.wait_for_cluster && length(local.all_vm_ids) > 0 ? 1 : 0
  source = "../shared/cluster-tag"

  endpoint     = local.anvil_mgmt_endpoint
  hsuser       = var.hsuser
  password     = var.admin_password
  triggers     = local.all_vm_ids
  wait_retries = var.cluster_api_wait_retries
  tag_command = join("; ", [
    for id in local.all_vm_ids :
    "az tag update --operation Merge --resource-id '${id}' --tags '${var.cluster_id_tag_key}=__CLUSTER_ID__' --output none"
  ])

  depends_on = [module.dsx, module.anvil_standalone, module.anvil_ha]
}
