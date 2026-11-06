#!/bin/sh

set -eu

if [ "${CONFIGURATION:-}" != "Release" ]; then
  exit 0
fi

validate_https_setting() {
  setting_name="$1"
  setting_value="$2"

  if [ -z "$setting_value" ]; then
    printf 'error: %s must be supplied by the private release configuration.\n' "$setting_name" >&2
    exit 1
  fi

  case "$setting_value" in
    https://*) ;;
    *)
      printf 'error: %s must use HTTPS.\n' "$setting_name" >&2
      exit 1
      ;;
  esac
}

validate_https_setting "REMOTE_PRIMARY_BASE_URL" "${REMOTE_PRIMARY_BASE_URL:-}"
validate_https_setting "REMOTE_FALLBACK_BASE_URL" "${REMOTE_FALLBACK_BASE_URL:-}"
validate_https_setting "REMOTE_TRANSLATION_BASE_URL" "${REMOTE_TRANSLATION_BASE_URL:-}"
validate_https_setting "REMOTE_IP_REGION_URL" "${REMOTE_IP_REGION_URL:-}"
validate_https_setting "REMOTE_REFERRAL_REWARDS_BASE_URL" "${REMOTE_REFERRAL_REWARDS_BASE_URL:-}"

support_email="${SUPPORT_EMAIL_ADDRESS:-}"
support_email_single_line="$(printf '%s' "$support_email" | tr -d '\r\n')"
if [ "$support_email" != "$support_email_single_line" ] || [ "${#support_email}" -gt 254 ] ||
   ! printf '%s' "$support_email" | LC_ALL=C grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then
  printf 'error: SUPPORT_EMAIL_ADDRESS must be supplied as a valid email address by the private release configuration.\n' >&2
  exit 1
fi
