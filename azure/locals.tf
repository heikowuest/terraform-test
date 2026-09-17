locals {
  is_standalone = var.deployment_mode == "standalone"
  is_ha         = var.deployment_mode == "ha"
  is_dsx_only   = var.deployment_mode == "dsx"
  creates_anvil = !local.is_dsx_only

  # <name> + per-deployment 5-char random tail (AWS parity): makes every
  # incarnation's resource IDs unique, so Azure activity logs and monitoring
  # never splice two deployments' histories together.
  prefix   = "${var.name}${random_string.run_suffix.result}"
  location = var.location != "" ? var.location : one(data.azurerm_resource_group.this[*].location)
  # ARM: domain = concat(name, '.azure')
  domain = "${local.prefix}.azure"

  # ARM: adminUsername = concat('user', uniqueString(name)). The OS account is
  # not used to operate Hammerspace - hs-init-admin-pw sets the product login.
  admin_username = var.admin_username != "" ? var.admin_username : "user${substr(sha1(lower(local.prefix)), 0, 13)}"

  vnet_resource_group = var.virtual_network_resource_group != "" ? var.virtual_network_resource_group : var.resource_group

  # ARM: builtinTags = {product: <brand>} union user tags. owner is always
  # present (IT automation stops VMs without it); var.tags may override it.
  tags = merge(
    { product = "Hammerspace" },
    { for k, v in { owner = var.owner } : k => v if trimspace(v) != "" },
    var.tags,
  )

  # --- 'Default' storage-type resolution (verbatim ARM noPremiumStorage logic:
  # Premium_LRS unless the instance type cannot do premium storage) ---
  no_premium_storage = [
    "Standard_D2_v3", "Standard_D4_v3", "Standard_D8_v3", "Standard_D16_v3",
    "Standard_D32_v3", "Standard_D48_v3", "Standard_D64_v3",
    "Standard_D2a_v4", "Standard_D4a_v4", "Standard_D8a_v4", "Standard_D16a_v4",
    "Standard_D32a_v4", "Standard_D48a_v4", "Standard_D64a_v4", "Standard_D96a_v4",
    "Standard_D2_v2", "Standard_D3_v2", "Standard_D4_v2", "Standard_D5_v2",
    "Standard_E2_v3", "Standard_E4_v3", "Standard_E8_v3", "Standard_E16_v3",
    "Standard_E20_v3", "Standard_E32_v3", "Standard_E48_v3", "Standard_E64_v3",
    "Standard_E64i_v3",
    "Standard_E2a_v4", "Standard_E4a_v4", "Standard_E8a_v4", "Standard_E16a_v4",
    "Standard_E20a_v4", "Standard_E32a_v4", "Standard_E48a_v4", "Standard_E64a_v4",
    "Standard_E96a_v4",
    "Standard_D11_v2", "Standard_D12_v2", "Standard_D13_v2", "Standard_D14_v2",
    "Standard_D15_v2",
    "Standard_A2_v2", "Standard_A4_v2", "Standard_A8_v2",
    "Standard_A2m_v2", "Standard_A4m_v2", "Standard_A8m_v2",
    "Standard_H8", "Standard_H16", "Standard_H8m", "Standard_H16m",
    "Standard_H16r", "Standard_H16mr",
    "Standard_F2", "Standard_F4", "Standard_F8", "Standard_F16",
    "Basic_A3", "Basic_A4",
    "Standard_A3", "Standard_A4", "Standard_A5", "Standard_A6", "Standard_A7",
    "Standard_A8", "Standard_A9", "Standard_A10", "Standard_A11",
    "Standard_D2", "Standard_D3", "Standard_D4",
    "Standard_D11", "Standard_D12", "Standard_D13", "Standard_D14",
    "Standard_G1", "Standard_G2", "Standard_G3", "Standard_G4", "Standard_G5",
  ]

  anvil_default_storage_type = contains(local.no_premium_storage, var.anvil_instance_type) ? "StandardSSD_LRS" : "Premium_LRS"
  dsx_default_storage_type   = contains(local.no_premium_storage, var.dsx_instance_type) ? "StandardSSD_LRS" : "Premium_LRS"

  anvil_os_storage_type = var.anvil_boot_disk_type == "Default" ? local.anvil_default_storage_type : var.anvil_boot_disk_type
  dsx_os_storage_type   = var.dsx_boot_disk_type == "Default" ? local.dsx_default_storage_type : var.dsx_boot_disk_type

  # --- High-performance metadata/data disks + the availability-set rule ---
  # Azure forbids PremiumV2/Ultra disks on VMs in availability sets. The
  # standalone Anvil is NOT placed in a set (pointless for a single VM), so
  # PremiumV2/Ultra metadata works there. DSX nodes normally keep the existing
  # availability-set behaviour, but when availability_zone is selected they
  # are zonal instead and can use PremiumV2/Ultra directly.
  perf_disk_types = ["PremiumV2_LRS", "UltraSSD_LRS"]

  anvil_meta_requested    = var.anvil_metadata_disk_type == "Default" ? local.anvil_default_storage_type : var.anvil_metadata_disk_type
  anvil_meta_fallback     = local.is_ha && contains(local.perf_disk_types, local.anvil_meta_requested)
  anvil_meta_storage_type = local.anvil_meta_fallback ? "Premium_LRS" : local.anvil_meta_requested

  dsx_data_requested    = var.dsx_data_disk_type == "Default" ? local.dsx_default_storage_type : var.dsx_data_disk_type
  dsx_data_fallback     = var.availability_zone == "" && contains(local.perf_disk_types, local.dsx_data_requested)
  dsx_data_storage_type = local.dsx_data_fallback ? "Premium_LRS" : local.dsx_data_requested

  # Prefix length of the data subnet CIDR - appended to the cluster/metadata
  # IP in custom data (ARM dataNetNum).
  data_subnet_prefixlen = split("/", data.azurerm_subnet.data.address_prefixes[0])[1]

  # --- Placement objects ---
  ppg_id = (
    var.use_proximity_placement_group
    ? (var.proximity_placement_group_name != ""
      ? one(data.azurerm_proximity_placement_group.existing[*].id)
    : one(azurerm_proximity_placement_group.this[*].id))
    : null
  )

  # The standalone Anvil is deliberately NOT in an availability set (a set
  # with one VM adds nothing, and it would forbid PremiumV2 metadata disks).
  anvil_avail_set_id = (
    local.is_ha
    ? (var.availability_set_name != ""
      ? one(data.azurerm_availability_set.existing[*].id)
    : one(azurerm_availability_set.anvil[*].id))
    : null
  )

  # Zonal DSX VMs cannot also be members of an availability set.
  # Empty availability_zone preserves the existing availability-set behaviour.
  dsx_avail_set_id = (
    var.availability_zone != ""
    ? null
    : (var.availability_set_name != ""
      ? one(data.azurerm_availability_set.existing[*].id)
    : one(azurerm_availability_set.dsx[*].id))
  )

  nsg_id = var.network_security_group_id != "" ? var.network_security_group_id : one(azurerm_network_security_group.this[*].id)

  # --- Cluster facts ---
  # anvil_ip = the DSX metadata / join target and the management endpoint:
  #   standalone -> the Anvil data NIC IP
  #   ha         -> the internal load balancer frontend IP (floating cluster IP)
  #   dsx        -> the existing cluster's IP, from var.anvil_ip
  anvil_ip = coalesce(
    one(module.anvil_standalone[*].anvil_ip),
    one(module.anvil_ha[*].cluster_ip),
    trimspace(var.anvil_ip) != "" ? var.anvil_ip : null,
  )

  # Endpoint the control host uses for the post-apply wait + cluster-ID
  # tagging: always the INTERNAL cluster IP - deploy from a machine with a
  # network path to the data subnet (VPN/peering), or set
  # wait_for_cluster = false when there is none.
  anvil_mgmt_endpoint = local.anvil_ip

  all_vm_ids = flatten([
    module.anvil_standalone[*].vm_id,
    module.anvil_ha[*].vm_ids,
    module.dsx[*].vm_ids,
  ])

  # Hammerspace port set from the marketplace NSG (single Allow rule, prio 2000).
  nsg_ports = [
    "22", "80", "111", "123", "137-139", "161", "443", "445", "662",
    "2049", "2224", "3049", "4379", "4505", "4506", "5405", "7789", "7790",
    "8443", "9000-9009", "9093", "9094-9099", "9200-9201", "9292",
    "9298-9299", "9399", "20048", "20491", "20492", "21064", "30048",
    "30049", "41001-41256", "50000", "51000", "52000-52008", "53000-53008",
    "53030",
  ]
}

resource "random_string" "run_suffix" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}
