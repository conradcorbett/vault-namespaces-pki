vault write sys/config/group-policy-application \
   group_policy_application_mode="any"

# Create new namespaces for Root and Intermediate CA 1
vault namespace create ns-root-ca
vault namespace create ns-ica-1

#--------------------------
# ns-root-ca namespace - Setup the Root CA
#--------------------------
VAULT_NAMESPACE=ns-root-ca vault secrets enable pki
VAULT_NAMESPACE=ns-root-ca vault secrets tune -max-lease-ttl=87600h pki
VAULT_NAMESPACE=ns-root-ca vault write -field=certificate pki/root/generate/internal \
     common_name="example.com" \
     issuer_name="root-2023" \
     ttl=87600h > root_2023_ca.crt
VAULT_NAMESPACE=ns-root-ca vault list pki/issuers/
VAULT_NAMESPACE=ns-root-ca vault write pki/roles/2023-servers allow_any_name=true
VAULT_NAMESPACE=ns-root-ca vault write pki/config/urls \
     issuing_certificates="$VAULT_ADDR/v1/pki/ca" \
     crl_distribution_points="$VAULT_ADDR/v1/pki/crl"

# Create a policy so users can sign with the Root CA
VAULT_NAMESPACE=ns-root-ca vault policy write sign-csr -<<EOF
path "pki/root/sign-intermediate" {
   capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

#--------------------------
# ns-ica-1 namespace - Setup the second namespace, following steps most likely completed by Vault Super Admin
#--------------------------
VAULT_NAMESPACE=ns-ica-1 vault policy write ica-1-admin -<<EOF
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
VAULT_NAMESPACE=ns-ica-1 vault auth enable userpass
VAULT_NAMESPACE=ns-ica-1 vault write auth/userpass/users/ica-1-admin1 password="changeme" policies=ica-1-admin

# Create an entity
VAULT_NAMESPACE=ns-ica-1 vault auth list -format=json | jq -r '.["userpass/"].accessor' > accessor.txt
VAULT_NAMESPACE=ns-ica-1 vault write -format=json identity/entity name="ICA1" | jq -r ".data.id" > entity_id.txt
VAULT_NAMESPACE=ns-ica-1 vault write identity/entity-alias name="ica-1-admin1" canonical_id=$(cat entity_id.txt) mount_accessor=$(cat accessor.txt)

# Create group in ns-root-ca that with sign-csr policy
VAULT_NAMESPACE=ns-root-ca vault write -format=json identity/group name="ica-1-admins" policies="sign-csr" member_entity_ids=$(cat entity_id.txt)

#--------------------------
# ns-ica-1 namespace - Login as admin user of Intermediate CA namespace, and create the Intermediate CA
#--------------------------
VAULT_NAMESPACE=ns-ica-1 vault login -field=token -method=userpass \
   username=ica-1-admin1 password="changeme" > token.txt
VAULT_NAMESPACE=ns-ica-1 VAULT_TOKEN=$(cat token.txt) vault secrets enable -path=pki_int pki
VAULT_NAMESPACE=ns-ica-1 VAULT_TOKEN=$(cat token.txt) vault secrets tune -max-lease-ttl=43800h pki_int
# Create the CSR
VAULT_NAMESPACE=ns-ica-1 VAULT_TOKEN=$(cat token.txt) vault write -format=json pki_int/intermediate/generate/internal \
     common_name="example.com Intermediate Authority" \
     issuer_name="example-dot-com-intermediate" \
     | jq -r '.data.csr' > pki_intermediate.csr
# Sign the CSR using the root CA, notice how the user has permissions to sign across namespace
VAULT_NAMESPACE=ns-root-ca VAULT_TOKEN=$(cat token.txt) vault write -format=json pki/root/sign-intermediate \
     issuer_ref="root-2023" \
     csr=@pki_intermediate.csr \
     format=pem_bundle ttl="43800h" \
     | jq -r '.data.certificate' > intermediate.cert.pem
VAULT_NAMESPACE=ns-ica-1 VAULT_TOKEN=$(cat token.txt) vault write pki_int/intermediate/set-signed certificate=@intermediate.cert.pem
VAULT_NAMESPACE=ns-ica-1 VAULT_TOKEN=$(cat token.txt) vault write pki_int/roles/example-dot-com \
     issuer_ref="$(vault read -field=default pki_int/config/issuers)" \
     allowed_domains="example.com" \
     allow_subdomains=true \
     max_ttl="720h"
VAULT_NAMESPACE=ns-ica-1 VAULT_TOKEN=$(cat token.txt) vault write pki_int/issue/example-dot-com common_name="test.example.com" ttl="24h"
