# vault-namespaces-pki
Quick demo to showcase using namespaces with Root CA and Intermediate CA.
The Root CA resides in a separate namespace from the Intermediate CA. An administrator of the Intermediate CA is able to sign the CSR using the pki endpoint in the Root CA namespace.
