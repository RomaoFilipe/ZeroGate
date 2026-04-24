# ============================================================
# ZeroGate — Cloudflare Zero Trust resources (v1.1)
# Manages: WAF geo-blocking, device posture rules
#
# Requires: CF_API_TOKEN with permissions:
#   Zone → Firewall Services → Edit
#   Account → Zero Trust → Edit
#   Account → Access: Apps and Policies → Edit
#
# Enable with: enable_geo_blocking = true / enable_device_posture = true
# in terraform.tfvars
# ============================================================

# ──────────────────────────────────────────────────────────────
# WAF — Geo-Blocking
# Blocks requests from high-risk countries at the Cloudflare
# edge, before they reach the tunnel or Authentik.
# ──────────────────────────────────────────────────────────────
resource "cloudflare_ruleset" "geo_block" {
  count = var.enable_geo_blocking ? 1 : 0

  zone_id     = var.cf_zone_id
  name        = "ZeroGate — Geo-Blocking"
  description = "Block traffic from high-risk countries"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules {
    action      = "block"
    description = "Block high-risk countries"
    enabled     = true

    # Build expression: (ip.geoip.country in {"RU" "CN" "KP" "IR"})
    expression = format(
      "(ip.geoip.country in {%s})",
      join(" ", [for c in var.block_countries : "\"${c}\""])
    )

    action_parameters {}
  }

  rules {
    action      = "log"
    description = "Log access from outside allowed countries"
    enabled     = var.allowed_countries_only

    # Log (not block) requests from countries not in the allowed list
    expression = format(
      "(not ip.geoip.country in {%s}) and (not ip.geoip.country in {%s})",
      join(" ", [for c in var.block_countries : "\"${c}\""]),
      join(" ", [for c in var.allowed_countries : "\"${c}\""])
    )

    action_parameters {}
  }
}

# Strict geo-blocking: only allow traffic from allowed_countries
resource "cloudflare_ruleset" "geo_allow_only" {
  count = var.enable_geo_blocking && var.allowed_countries_only ? 1 : 0

  zone_id     = var.cf_zone_id
  name        = "ZeroGate — Geo-Allow-Only"
  description = "Allow only traffic from specified countries"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules {
    action      = "block"
    description = "Block all countries except allowed list"
    enabled     = true

    expression = format(
      "(not ip.geoip.country in {%s})",
      join(" ", [for c in var.allowed_countries : "\"${c}\""])
    )

    action_parameters {}
  }
}

# ──────────────────────────────────────────────────────────────
# Device Posture — WARP Client Required
# Users must have Cloudflare WARP installed and connected.
# This validates the device at the network level before
# Authentik authentication even begins.
# ──────────────────────────────────────────────────────────────
resource "cloudflare_device_posture_rule" "warp_client" {
  count = var.enable_device_posture ? 1 : 0

  account_id  = var.cf_account_id
  name        = "ZeroGate — WARP Client Connected"
  type        = "warp"
  description = "Device must have Cloudflare WARP client running"
  schedule    = "5m"
  expiration  = "10m"
}

# Device Posture — Disk Encryption (Windows)
resource "cloudflare_device_posture_rule" "disk_encryption_windows" {
  count = var.enable_device_posture ? 1 : 0

  account_id  = var.cf_account_id
  name        = "ZeroGate — Disk Encryption (Windows)"
  type        = "disk_encryption"
  description = "Require BitLocker encryption on Windows devices"
  schedule    = "1h"
  expiration  = "2h"

  match {
    platform = "windows"
  }

  input {
    require_all = true
  }
}

# Device Posture — Disk Encryption (macOS)
resource "cloudflare_device_posture_rule" "disk_encryption_mac" {
  count = var.enable_device_posture ? 1 : 0

  account_id  = var.cf_account_id
  name        = "ZeroGate — Disk Encryption (macOS)"
  type        = "disk_encryption"
  description = "Require FileVault encryption on macOS devices"
  schedule    = "1h"
  expiration  = "2h"

  match {
    platform = "mac"
  }

  input {
    require_all = true
  }
}

# Device Posture — OS Version (minimum version enforcement)
resource "cloudflare_device_posture_rule" "os_version_windows" {
  count = var.enable_device_posture ? 1 : 0

  account_id  = var.cf_account_id
  name        = "ZeroGate — Windows OS Version"
  type        = "os_version"
  description = "Require Windows 10 21H2 or later (build 19044)"
  schedule    = "1h"
  expiration  = "2h"

  match {
    platform = "windows"
  }

  input {
    version          = "10.0.19044"
    operator         = ">="
    os_distro_name   = "windows"
    os_distro_revision = ""
  }
}

# Device Posture — OS Version (macOS)
resource "cloudflare_device_posture_rule" "os_version_mac" {
  count = var.enable_device_posture ? 1 : 0

  account_id  = var.cf_account_id
  name        = "ZeroGate — macOS Version"
  type        = "os_version"
  description = "Require macOS 13 (Ventura) or later"
  schedule    = "1h"
  expiration  = "2h"

  match {
    platform = "mac"
  }

  input {
    version  = "13.0.0"
    operator = ">="
  }
}

# ──────────────────────────────────────────────────────────────
# WAF Rate-Limiting — Brute Force at Edge
# Blocks IPs attempting > 20 login requests per minute,
# in addition to the Authentik reputation policy.
# ──────────────────────────────────────────────────────────────
resource "cloudflare_ruleset" "rate_limit_auth" {
  count = var.enable_geo_blocking ? 1 : 0

  zone_id     = var.cf_zone_id
  name        = "ZeroGate — Auth Rate Limiting"
  description = "Rate-limit authentication endpoint to prevent brute force"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules {
    action      = "block"
    description = "Block IPs sending > 20 auth requests per minute"
    enabled     = true

    expression = "(http.request.uri.path contains \"/application/o/authorize/\")"

    action_parameters {
      response {
        status_code  = 429
        content_type = "application/json"
        content      = "{\"error\":\"rate_limited\",\"message\":\"Too many requests. Please wait before trying again.\"}"
      }
    }

    ratelimit {
      characteristics     = ["ip.src"]
      period              = 60
      requests_per_period = 20
      mitigation_timeout  = 600 # Block for 10 minutes
    }
  }
}

# ──────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────
output "geo_block_ruleset_id" {
  description = "Cloudflare WAF geo-blocking ruleset ID"
  value       = var.enable_geo_blocking ? cloudflare_ruleset.geo_block[0].id : "geo-blocking disabled"
}

output "device_posture_rule_ids" {
  description = "Cloudflare device posture rule IDs"
  value = var.enable_device_posture ? {
    warp_client           = cloudflare_device_posture_rule.warp_client[0].id
    disk_encryption_win   = cloudflare_device_posture_rule.disk_encryption_windows[0].id
    disk_encryption_mac   = cloudflare_device_posture_rule.disk_encryption_mac[0].id
    os_version_windows    = cloudflare_device_posture_rule.os_version_windows[0].id
    os_version_mac        = cloudflare_device_posture_rule.os_version_mac[0].id
  } : {}
}
