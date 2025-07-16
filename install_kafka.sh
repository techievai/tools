#!/bin/bash
set -euo pipefail
trap 'echo "[ERROR] Failed at line $LINENO: $BASH_COMMAND"' ERR

HOST_ENTRY=$1
RAW_KAFKA_VERSION=$2
MODE=${3:-zk}

HOSTNAME=""
HOSTIP=""
KAFKA_VERSION=""
KAFKA_DIR=""
KAFKA_INSTALL_DIR=""
DOWNLOAD_URL=""
CLUSTER_ID=""
KAFKA_CONFIG=""

# Normalize Kafka version input
normalize_kafka_version() {
  local version=$(echo "$RAW_KAFKA_VERSION" | awk '{print tolower($0)}')
  if [[ "$version" == "kafka2" ]]; then
    KAFKA_VERSION="kafka2"
    DOWNLOAD_URL="https://archive.apache.org/dist/kafka/2.8.0/kafka_2.13-2.8.0.tgz"
    KAFKA_DIR="kafka_2.13-2.8.0"
    KAFKA_INSTALL_DIR="/opt/kafka"
  elif [[ "$version" == "kafka3" ]]; then
    KAFKA_VERSION="kafka3"
    DOWNLOAD_URL="https://downloads.apache.org/kafka/3.6.1/kafka_2.13-3.6.1.tgz"
    KAFKA_DIR="kafka_2.13-3.6.1"
    KAFKA_INSTALL_DIR="/opt/kafka3"
  else
    echo "[ERROR] Invalid Kafka version: $RAW_KAFKA_VERSION"
    exit 1
  fi
}

parse_input() {
  if [ -z "$HOST_ENTRY" ] || [ -z "$RAW_KAFKA_VERSION" ]; then
    echo "Usage: $0 <hostname:hostip> <Kafka2|Kafka3> [zk|kraft]"
    exit 1
  fi

  HOSTNAME=$(echo "$HOST_ENTRY" | cut -d: -f1)
  HOSTIP=$(echo "$HOST_ENTRY" | cut -d: -f2)
  normalize_kafka_version
}

install_prerequisites() {
  echo "[INFO] Installing prerequisites..."
  sudo dnf install -y java-11-openjdk-devel wget net-tools curl unzip hostname nc
}

set_hostname() {
  echo "[INFO] Setting system hostname to $HOSTNAME..."
  sudo hostnamectl set-hostname "$HOSTNAME"
  echo "$HOSTNAME" | sudo tee /etc/hostname
}

update_hosts_file() {
  echo "[INFO] Updating /etc/hosts..."
  if ! grep -q "$HOSTNAME" /etc/hosts; then
    echo "$HOSTIP $HOSTNAME" | sudo tee -a /etc/hosts
  else
    echo "[INFO] Hostname already exists in /etc/hosts."
  fi
}

download_kafka() {
  echo "[INFO] Downloading Kafka from $DOWNLOAD_URL..."
  wget $DOWNLOAD_URL -O kafka.tgz || {
    echo "[ERROR] Failed to download Kafka"
    exit 1
  }

  echo "[INFO] Extracting Kafka..."
  tar -xzf kafka.tgz
  rm -f kafka.tgz

  if [ ! -d "$KAFKA_DIR" ]; then
    echo "[ERROR] Kafka directory '$KAFKA_DIR' not found after extraction"
    exit 1
  fi

  echo "[INFO] Moving Kafka to $KAFKA_INSTALL_DIR..."
  sudo rm -rf "$KAFKA_INSTALL_DIR"
  sudo mv "$KAFKA_DIR" "$KAFKA_INSTALL_DIR"
  sudo chown -R "$USER":"$USER" "$KAFKA_INSTALL_DIR"
}

start_zookeeper() {
  echo "[INFO] Starting Zookeeper..."
  "$KAFKA_INSTALL_DIR/bin/zookeeper-server-start.sh" -daemon "$KAFKA_INSTALL_DIR/config/zookeeper.properties"
  sleep 5
}

configure_kafka_zookeeper() {
  echo "[INFO] Configuring Kafka (Zookeeper-based)..."
  KAFKA_CONFIG="$KAFKA_INSTALL_DIR/config/server.properties"
  sed -i "s|broker.id=.*|broker.id=0|" "$KAFKA_CONFIG"
  sed -i "s|#listeners=PLAINTEXT://:9092|listeners=PLAINTEXT://$HOSTIP:9092|" "$KAFKA_CONFIG"
  sed -i "s|log.dirs=.*|log.dirs=/tmp/kafka-logs|" "$KAFKA_CONFIG"
  sed -i "s|zookeeper.connect=.*|zookeeper.connect=localhost:2181|" "$KAFKA_CONFIG"
}

start_kafka_zookeeper() {
  echo "[INFO] Starting Kafka (Zookeeper mode)..."
  "$KAFKA_INSTALL_DIR/bin/kafka-server-start.sh" -daemon "$KAFKA_CONFIG"
  sleep 5
}

configure_kafka_kraft() {
  echo "[INFO] Configuring Kafka (KRaft mode)..."
  KAFKA_CONFIG="$KAFKA_INSTALL_DIR/config/kraft/server.properties"

  CLUSTER_ID=$("$KAFKA_INSTALL_DIR/bin/kafka-storage.sh" random-uuid)
  echo "[INFO] Generated Cluster ID: $CLUSTER_ID"

  "$KAFKA_INSTALL_DIR/bin/kafka-storage.sh" format -t "$CLUSTER_ID" -c "$KAFKA_CONFIG"

  sed -i "s|#listeners=PLAINTEXT://:9092|listeners=PLAINTEXT://$HOSTIP:9092|" "$KAFKA_CONFIG"
  sed -i "s|log.dirs=.*|log.dirs=/tmp/kraft-logs|" "$KAFKA_CONFIG"
}

start_kafka_kraft() {
  echo "[INFO] Starting Kafka (KRaft mode)..."
  "$KAFKA_INSTALL_DIR/bin/kafka-server-start.sh" -daemon "$KAFKA_CONFIG"
  sleep 5
}

create_systemd_service_files() {
  echo "[INFO] Creating systemd service files..."

  # Zookeeper service unit (only if mode is zk)
  if [[ "$MODE" == "zk" ]]; then
    sudo tee /etc/systemd/system/zookeeper.service > /dev/null <<EOF
[Unit]
Description=Apache Zookeeper Server
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$KAFKA_INSTALL_DIR/bin/zookeeper-server-start.sh $KAFKA_INSTALL_DIR/config/zookeeper.properties
ExecStop=$KAFKA_INSTALL_DIR/bin/zookeeper-server-stop.sh
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
  fi

  # Kafka service unit
  sudo tee /etc/systemd/system/kafka.service > /dev/null <<EOF
[Unit]
Description=Apache Kafka Server
After=network.target
Requires=$( [[ "$MODE" == "zk" ]] && echo "zookeeper.service" || echo "")

[Service]
Type=simple
User=$USER
ExecStart=$KAFKA_INSTALL_DIR/bin/kafka-server-start.sh $KAFKA_CONFIG
ExecStop=$KAFKA_INSTALL_DIR/bin/kafka-server-stop.sh
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF

  echo "[INFO] Reloading systemd daemon and enabling services..."
  sudo systemctl daemon-reexec
  sudo systemctl daemon-reload

  if [[ "$MODE" == "zk" ]]; then
    sudo systemctl enable zookeeper.service
    sudo systemctl enable kafka.service
    echo "[INFO] Starting Zookeeper and Kafka services..."
    sudo systemctl start zookeeper.service
    sudo systemctl start kafka.service
  else
    sudo systemctl enable kafka.service
    echo "[INFO] Starting Kafka service (KRaft mode)..."
    sudo systemctl start kafka.service
  fi
}


test_kafka() {
  echo "[INFO] Testing Kafka availability on $HOSTIP:9092..."
  if nc -z "$HOSTIP" 9092; then
    echo "[INFO] Kafka port is open. Listing topics:"
    "$KAFKA_INSTALL_DIR/bin/kafka-topics.sh" --list --bootstrap-server "$HOSTIP:9092" || {
      echo "[WARNING] Kafka is running but couldn't list topics (may be empty or not ready yet)"
    }
    echo "[SUCCESS] Kafka appears to be running correctly."
  else
    echo "[ERROR] Kafka is not reachable on $HOSTIP:9092"
    exit 1
  fi
}


run_setup() {
  if [[ "$KAFKA_VERSION" == "kafka2" ]]; then
    # Kafka2 only supports Zookeeper
    start_zookeeper
    configure_kafka_zookeeper
  elif [[ "$KAFKA_VERSION" == "kafka3" ]]; then
    if [[ "$MODE" == "zk" ]]; then
      start_zookeeper
      configure_kafka_zookeeper
    elif [[ "$MODE" == "kraft" ]]; then
      configure_kafka_kraft
    else
      echo "[ERROR] Invalid mode for Kafka3. Use 'zk' or 'kraft'."
      exit 1
    fi
  fi

  create_systemd_service_files
}



### ========== Main ========== ###
parse_input
set_hostname
install_prerequisites
update_hosts_file
download_kafka
run_setup
test_kafka

echo "[SUCCESS] Kafka installation and setup complete at $KAFKA_INSTALL_DIR."
