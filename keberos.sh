#!/bin/bash
set -euo pipefail
trap 'echo "[ERROR] Failed at line $LINENO: $BASH_COMMAND"' ERR

### ====== Input Validation ====== ###
if [ $# -lt 2 ]; then
  echo "Usage: $0 <REALM_NAME> <KDC_HOST>"
  exit 1
fi

REALM_NAME=$1
KDC_HOST=$2
KADMIN_PRINCIPAL="admin/admin"
KADMIN_PASSWORD="Admin@123"

# Paths and host details
KAFKA_INSTALL_DIR=${KAFKA_HOME:-/opt/kafka}
KEYTAB_DIR="/etc/security/keytabs"
FQDN=$(hostname -f)
DOMAIN_LOWER=$(hostname -d | tr '[:upper:]' '[:lower:]')
KAFKA_PRINCIPAL="kafka/$FQDN@$REALM_NAME"
ZOOKEEPER_PRINCIPAL="zookeeper/$FQDN@$REALM_NAME"
KAFKA_KEYTAB="$KEYTAB_DIR/kafka.keytab"
ZOOKEEPER_KEYTAB="$KEYTAB_DIR/zookeeper.keytab"

krb5_conf_file="/etc/krb5.conf"
kdc_conf_dir="/var/kerberos/krb5kdc"
kdc_conf_file="$kdc_conf_dir/kdc.conf"
kadm5_acl_file="$kdc_conf_dir/kadm5.acl"

### ====== Functions ====== ###

install_kerberos_packages() {
  echo "[INFO] Installing Kerberos KDC and client packages..."
  sudo dnf install -y krb5-server krb5-libs krb5-workstation
}

configure_krb5_conf() {
  echo "[INFO] Configuring /etc/krb5.conf..."
  sudo tee "$krb5_conf_file" > /dev/null <<EOF
[logging]
 default = FILE:/var/log/krb5libs.log
 kdc = FILE:/var/log/krb5kdc.log
 admin_server = FILE:/var/log/kadmind.log

[libdefaults]
 default_realm = $REALM_NAME
 dns_lookup_realm = false
 ticket_lifetime = 24h
 renew_lifetime = 7d
 forwardable = true
 rdns = false

[realms]
 $REALM_NAME = {
  kdc = $KDC_HOST
  admin_server = $KDC_HOST
 }

[domain_realm]
 .$DOMAIN_LOWER = $REALM_NAME
 $DOMAIN_LOWER = $REALM_NAME
EOF
}

configure_kdc() {
  echo "[INFO] Configuring KDC database and ACLs..."
  sudo rm -rf "$kdc_conf_dir"/*
  sudo tee "$kdc_conf_file" > /dev/null <<EOF
[kdcdefaults]
 kdc_ports = 88
 kdc_tcp_ports = 88

[realms]
 $REALM_NAME = {
  database_name = $kdc_conf_dir/principal
  admin_keytab = $kdc_conf_dir/kadm5.keytab
  acl_file = $kadm5_acl_file
  dict_file = /usr/share/dict/words
  key_stash_file = $kdc_conf_dir/.k5.$REALM_NAME
  kdc_ports = 88
  kdc_tcp_ports = 88
 }
EOF

  sudo tee "$kadm5_acl_file" > /dev/null <<EOF
$KADMIN_PRINCIPAL *
EOF

  echo "$KADMIN_PASSWORD" | sudo kdb5_util create -s -r "$REALM_NAME" <<EOF
$KADMIN_PASSWORD
$KADMIN_PASSWORD
EOF
}

start_kdc_services() {
  echo "[INFO] Starting krb5kdc and kadmind services..."
  sudo systemctl enable --now krb5kdc
  sudo systemctl enable --now kadmin
}

create_principals_and_keytabs() {
  echo "[INFO] Creating principals and keytabs..."
  sudo mkdir -p "$KEYTAB_DIR"

  echo "$KADMIN_PASSWORD" | kadmin.local <<EOF
addprinc -pw $KADMIN_PASSWORD $KADMIN_PRINCIPAL
addprinc -randkey $KAFKA_PRINCIPAL
addprinc -randkey $ZOOKEEPER_PRINCIPAL
ktadd -k $KAFKA_KEYTAB $KAFKA_PRINCIPAL
ktadd -k $ZOOKEEPER_KEYTAB $ZOOKEEPER_PRINCIPAL
EOF

  sudo chmod 600 "$KAFKA_KEYTAB" "$ZOOKEEPER_KEYTAB"
  sudo chown "$USER":"$USER" "$KAFKA_KEYTAB" "$ZOOKEEPER_KEYTAB"
}

configure_kafka_server_properties() {
  echo "[INFO] Configuring Kafka for Kerberos-only access..."

  CONFIG_FILE="$KAFKA_INSTALL_DIR/config/server.properties"
  sudo tee -a "$CONFIG_FILE" > /dev/null <<EOF

# Kerberos SASL settings
listeners=SASL_PLAINTEXT://$FQDN:9092
advertised.listeners=SASL_PLAINTEXT://$FQDN:9092
security.inter.broker.protocol=SASL_PLAINTEXT
sasl.mechanism.inter.broker.protocol=GSSAPI
sasl.enabled.mechanisms=GSSAPI
authorizer.class.name=kafka.security.authorizer.AclAuthorizer
super.users=User:admin
allow.everyone.if.no.acl.found=false
EOF
}

configure_zookeeper_security() {
  echo "[INFO] Enabling Kerberos authentication in Zookeeper..."
  ZK_CONFIG="$KAFKA_INSTALL_DIR/config/zookeeper.properties"

  sudo tee -a "$ZK_CONFIG" > /dev/null <<EOF

authProvider.1=org.apache.zookeeper.server.auth.SASLAuthenticationProvider
requireClientAuthScheme=sasl
jaasLoginRenew=3600000
EOF
}

configure_jaas_files() {
  echo "[INFO] Creating JAAS configuration files..."

  SERVER_JAAS="$KAFKA_INSTALL_DIR/config/kafka_server_jaas.conf"
  ZK_JAAS="$KAFKA_INSTALL_DIR/config/zookeeper_jaas.conf"

  sudo tee "$SERVER_JAAS" > /dev/null <<EOF
KafkaServer {
  com.sun.security.auth.module.Krb5LoginModule required
  useKeyTab=true
  storeKey=true
  keyTab="$KAFKA_KEYTAB"
  principal="$KAFKA_PRINCIPAL";
};
EOF

  sudo tee "$ZK_JAAS" > /dev/null <<EOF
Server {
  com.sun.security.auth.module.Krb5LoginModule required
  useKeyTab=true
  storeKey=true
  keyTab="$ZOOKEEPER_KEYTAB"
  principal="$ZOOKEEPER_PRINCIPAL";
};
EOF
}

enable_kerberos_in_services() {
  echo "[INFO] Configuring systemd to use Kerberos JAAS configs..."

  sudo mkdir -p /etc/systemd/system/kafka.service.d
  sudo mkdir -p /etc/systemd/system/zookeeper.service.d

  sudo tee /etc/systemd/system/kafka.service.d/kerberos.conf > /dev/null <<EOF
[Service]
Environment="KAFKA_OPTS=-Djava.security.auth.login.config=$KAFKA_INSTALL_DIR/config/kafka_server_jaas.conf"
EOF

  sudo tee /etc/systemd/system/zookeeper.service.d/kerberos.conf > /dev/null <<EOF
[Service]
Environment="KAFKA_OPTS=-Djava.security.auth.login.config=$KAFKA_INSTALL_DIR/config/zookeeper_jaas.conf"
EOF

  sudo systemctl daemon-reload
  sudo systemctl restart zookeeper.service || echo "[WARN] Zookeeper may not be running."
  sudo systemctl restart kafka.service
}

verify_kerberos() {
  echo "[INFO] Verifying Kerberos authentication with kinit..."
  kinit -kt "$KAFKA_KEYTAB" "$KAFKA_PRINCIPAL"
  klist
}

### ====== Main Flow ====== ###
install_kerberos_packages
configure_krb5_conf
configure_kdc
start_kdc_services
create_principals_and_keytabs
configure_kafka_server_properties
configure_zookeeper_security
configure_jaas_files
enable_kerberos_in_services
verify_kerberos

echo "[SUCCESS] Kafka and Zookeeper are now Kerberized under realm: $REALM_NAME"
