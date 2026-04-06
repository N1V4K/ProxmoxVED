#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/misc/build.func)

# Copyright (c) 2021-2026 community-scripts ORG
# Author: MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/lobehub/lobehub
#
# Modification:
# - Increased default container RAM
# - Added temporary swap during build
# - Reduced build parallelism
# - Applied NODE_OPTIONS directly to the build command
# - Avoided $STD for pnpm build commands so environment variables are preserved
# - Increased Node.js heap size further to prevent OOM during build

APP="LobeHub"
var_tags="${var_tags:-ai;chat}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-24576}"
var_disk="${var_disk:-15}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

BUILD_LOG="/root/lobehub-build.log"
SWAPFILE="/swapfile"
SWAPSIZE="12G"
NODE_HEAP_MB="${NODE_HEAP_MB:-12288}"

header_info "$APP"
variables
color
catch_errors

ensure_swap() {
  if swapon --show | grep -q "^${SWAPFILE}"; then
    msg_ok "Swap already active: ${SWAPFILE}"
    return 0
  fi

  if [ -f "${SWAPFILE}" ]; then
    rm -f "${SWAPFILE}"
  fi

  msg_info "Creating temporary swap (${SWAPSIZE})"
  if ! fallocate -l "${SWAPSIZE}" "${SWAPFILE}" 2>/dev/null; then
    dd if=/dev/zero of="${SWAPFILE}" bs=1M count=12288 status=progress
  fi
  chmod 600 "${SWAPFILE}"
  mkswap "${SWAPFILE}" >/dev/null
  swapon "${SWAPFILE}"
  msg_ok "Temporary swap enabled"
}

cleanup_swap() {
  if swapon --show | grep -q "^${SWAPFILE}"; then
    msg_info "Disabling temporary swap"
    swapoff "${SWAPFILE}" || true
  fi
  [ -f "${SWAPFILE}" ] && rm -f "${SWAPFILE}"
  msg_ok "Temporary swap cleaned up"
}

build_lobehub() {
  cd /opt/lobehub || return 1

  : > "${BUILD_LOG}"

  export CI=1
  export npm_config_jobs=1
  export NEXT_TELEMETRY_DISABLED=1
  export NODE_OPTIONS="--max-old-space-size=${NODE_HEAP_MB}"

  msg_info "Build environment"
  echo "NODE_HEAP_MB=${NODE_HEAP_MB}" | tee -a "${BUILD_LOG}"
  echo "NODE_OPTIONS=${NODE_OPTIONS}" | tee -a "${BUILD_LOG}"
  echo "CI=${CI}" | tee -a "${BUILD_LOG}"
  echo "npm_config_jobs=${npm_config_jobs}" | tee -a "${BUILD_LOG}"
  free -h | tee -a "${BUILD_LOG}"
  swapon --show | tee -a "${BUILD_LOG}" || true

  msg_info "Installing dependencies"
  pnpm install 2>&1 | tee -a "${BUILD_LOG}"
  install_rc=${PIPESTATUS[0]}
  if [ "${install_rc}" -ne 0 ]; then
    msg_error "pnpm install failed. See ${BUILD_LOG}"
    return 1
  fi

  msg_info "Building application (this can take a while)"
  NODE_OPTIONS="--max-old-space-size=${NODE_HEAP_MB}" CI=1 npm_config_jobs=1 pnpm run build:docker 2>&1 | tee -a "${BUILD_LOG}"
  build_rc=${PIPESTATUS[0]}
  if [ "${build_rc}" -ne 0 ]; then
    msg_error "pnpm run build:docker failed. See ${BUILD_LOG}"
    return 1
  fi

  unset NODE_OPTIONS CI npm_config_jobs NEXT_TELEMETRY_DISABLED
  return 0
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/lobehub ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi

  if check_for_gh_release "lobehub" "lobehub/lobehub"; then
    msg_info "Stopping Services"
    systemctl stop lobehub
    msg_ok "Stopped Services"

    msg_info "Backing up Data"
    cp /opt/lobehub/.env /opt/lobehub.env.bak
    msg_ok "Backed up Data"

    CLEAN_INSTALL=1 fetch_and_deploy_gh_release "lobehub" "lobehub/lobehub" "tarball"

    msg_info "Restoring Configuration"
    cp /opt/lobehub.env.bak /opt/lobehub/.env
    rm -f /opt/lobehub.env.bak
    msg_ok "Restored Configuration"

    ensure_swap

    msg_info "Building Application"
    if ! build_lobehub; then
      cleanup_swap
      msg_error "Build failed. Full log: ${BUILD_LOG}"
      exit 1
    fi
    msg_ok "Built Application"

    cleanup_swap

    msg_info "Running Database Migrations"
    cd /opt/lobehub || exit 1
    set -a
    source /opt/lobehub/.env
    set +a
    $STD node /opt/lobehub/.next/standalone/docker.cjs
    msg_ok "Ran Database Migrations"

    msg_info "Starting Services"
    systemctl start lobehub
    msg_ok "Started Services"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3210${CL}"
