#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lab/gcp/common.sh
source "$script_dir/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/gcp/setup-wif.sh [options]

Creates/verifies GitHub Actions Workload Identity Federation for OpenPhone lab
runs. This avoids long-lived JSON service account keys.

Options:
  --project <id>            GCP project. Default: OPENPHONE_GCP_PROJECT/openphone-lab.
  --repo <owner/name>       GitHub repo allowed to federate. Default: secondly-com/OpenPhone.
  --pool <id>               WIF pool id. Default: github.
  --provider <id>           WIF provider id. Default: secondly-openphone.
  --service-account <id>    Service account id. Default: github-openphone-lab.
  --set-github-vars         Write required GitHub repo variables with gh.
  -h, --help                Show this help.
EOF
}

project="$OPENPHONE_GCP_PROJECT"
repo="secondly-com/OpenPhone"
pool_id="github"
provider_id="secondly-openphone"
service_account_id="github-openphone-lab"
set_github_vars=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || die "--project requires a value"
      project="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value"
      repo="$2"
      shift 2
      ;;
    --pool)
      [[ $# -ge 2 ]] || die "--pool requires a value"
      pool_id="$2"
      shift 2
      ;;
    --provider)
      [[ $# -ge 2 ]] || die "--provider requires a value"
      provider_id="$2"
      shift 2
      ;;
    --service-account)
      [[ $# -ge 2 ]] || die "--service-account requires a value"
      service_account_id="$2"
      shift 2
      ;;
    --set-github-vars)
      set_github_vars=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

need_gcloud

info "Using GCP project: $project"
gcloud services enable \
  compute.googleapis.com \
  iap.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  artifactregistry.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  --project "$project"

project_number="$(gcloud projects describe "$project" --format='value(projectNumber)')"
sa_email="${service_account_id}@${project}.iam.gserviceaccount.com"
wif_attribute_mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref,attribute.workflow=assertion.workflow,attribute.workflow_ref=assertion.workflow_ref"
wif_release_workflow_ref="${repo}/.github/workflows/release.yml@refs/heads/main"
wif_lab_workflow_ref="${repo}/.github/workflows/gcp-lab.yml@refs/heads/main"
wif_cache_refresh_workflow_ref="${repo}/.github/workflows/gcp-cache-refresh.yml@refs/heads/main"
wif_attribute_condition="assertion.repository == '${repo}' && (assertion.workflow_ref == '${wif_release_workflow_ref}' || assertion.workflow_ref == '${wif_lab_workflow_ref}' || assertion.workflow_ref == '${wif_cache_refresh_workflow_ref}')"

if ! gcloud iam service-accounts describe "$sa_email" --project "$project" >/dev/null 2>&1; then
  info "Creating service account: $sa_email"
  gcloud iam service-accounts create "$service_account_id" \
    --project "$project" \
    --display-name "GitHub OpenPhone Lab"
else
  info "Service account already exists: $sa_email"
fi

if ! gcloud iam workload-identity-pools describe "$pool_id" \
  --project "$project" \
  --location global >/dev/null 2>&1; then
  info "Creating WIF pool: $pool_id"
  gcloud iam workload-identity-pools create "$pool_id" \
    --project "$project" \
    --location global \
    --display-name "GitHub Actions"
else
  info "WIF pool already exists: $pool_id"
fi

if ! gcloud iam workload-identity-pools providers describe "$provider_id" \
  --project "$project" \
  --location global \
  --workload-identity-pool "$pool_id" >/dev/null 2>&1; then
  info "Creating WIF provider: $provider_id"
  gcloud iam workload-identity-pools providers create-oidc "$provider_id" \
    --project "$project" \
    --location global \
    --workload-identity-pool "$pool_id" \
    --display-name "$repo" \
    --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "$wif_attribute_mapping" \
    --attribute-condition "$wif_attribute_condition"
else
  info "Updating WIF provider condition: $provider_id"
  gcloud iam workload-identity-pools providers update-oidc "$provider_id" \
    --project "$project" \
    --location global \
    --workload-identity-pool "$pool_id" \
    --display-name "$repo" \
    --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "$wif_attribute_mapping" \
    --attribute-condition "$wif_attribute_condition" >/dev/null
fi

principal="principalSet://iam.googleapis.com/projects/${project_number}/locations/global/workloadIdentityPools/${pool_id}/attribute.repository/${repo}"
provider_resource="projects/${project_number}/locations/global/workloadIdentityPools/${pool_id}/providers/${provider_id}"

info "Binding GitHub repo principal to service account"
gcloud iam service-accounts add-iam-policy-binding "$sa_email" \
  --project "$project" \
  --role roles/iam.workloadIdentityUser \
  --member "$principal" >/dev/null

roles=(
  roles/compute.instanceAdmin.v1
  roles/iam.serviceAccountUser
  roles/iap.tunnelResourceAccessor
  roles/serviceusage.serviceUsageConsumer
)

for role in "${roles[@]}"; do
  info "Ensuring project role $role"
  gcloud projects add-iam-policy-binding "$project" \
    --member "serviceAccount:$sa_email" \
    --role "$role" >/dev/null
done

iap_firewall_rule="openphone-lab-allow-iap-ssh"
if gcloud compute firewall-rules describe "$iap_firewall_rule" \
  --project "$project" >/dev/null 2>&1; then
  info "Ensuring IAP SSH firewall rule: $iap_firewall_rule"
  gcloud compute firewall-rules update "$iap_firewall_rule" \
    --project "$project" \
    --rules tcp:22 \
    --source-ranges 35.235.240.0/20 \
    --target-tags openphone-lab >/dev/null
else
  info "Creating IAP SSH firewall rule: $iap_firewall_rule"
  gcloud compute firewall-rules create "$iap_firewall_rule" \
    --project "$project" \
    --network "$OPENPHONE_GCP_NETWORK" \
    --direction INGRESS \
    --priority 1000 \
    --action ALLOW \
    --rules tcp:22 \
    --source-ranges 35.235.240.0/20 \
    --target-tags openphone-lab \
    --description "Allow SSH to OpenPhone lab VMs only through Google Cloud IAP" >/dev/null
fi

for broad_rule in default-allow-ssh default-allow-rdp; do
  if gcloud compute firewall-rules describe "$broad_rule" \
    --project "$project" >/dev/null 2>&1; then
    info "Disabling broad default ingress rule: $broad_rule"
    gcloud compute firewall-rules update "$broad_rule" \
      --project "$project" \
      --disabled >/dev/null
  fi
done

if [[ "$set_github_vars" == true ]]; then
  need_cmd gh
  info "Writing GitHub repo variables for $repo"
  gh variable set OPENPHONE_GCP_PROJECT --repo "$repo" --body "$project"
  gh variable set OPENPHONE_GCP_REGION --repo "$repo" --body "$OPENPHONE_GCP_REGION"
  gh variable set OPENPHONE_GCP_ZONE --repo "$repo" --body "$OPENPHONE_GCP_ZONE"
  gh variable set OPENPHONE_GCP_WORKLOAD_IDENTITY_PROVIDER --repo "$repo" --body "$provider_resource"
  gh variable set OPENPHONE_GCP_SERVICE_ACCOUNT --repo "$repo" --body "$sa_email"
  gh variable set OPENPHONE_GCP_MACHINE_TYPE --repo "$repo" --body "$OPENPHONE_GCP_MACHINE_TYPE"
  gh variable set OPENPHONE_GCP_BOOT_DISK_SIZE --repo "$repo" --body "$OPENPHONE_GCP_BOOT_DISK_SIZE"
  gh variable set OPENPHONE_GCP_BOOT_DISK_TYPE --repo "$repo" --body "$OPENPHONE_GCP_BOOT_DISK_TYPE"
  gh variable set OPENPHONE_GCP_TUNNEL_THROUGH_IAP --repo "$repo" --body "$OPENPHONE_GCP_TUNNEL_THROUGH_IAP"
fi

cat <<EOF
OpenPhone GCP WIF ready.

OPENPHONE_GCP_PROJECT=$project
OPENPHONE_GCP_WORKLOAD_IDENTITY_PROVIDER=$provider_resource
OPENPHONE_GCP_SERVICE_ACCOUNT=$sa_email
EOF
