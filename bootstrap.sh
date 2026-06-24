#!/usr/bin/env bash

# Read node role
ROLE="${1:-master}"

# Disable needrestart
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

echo "==> Configuring node: $ROLE"

# Install base packages
apt-get update
apt-get install -y openjdk-17-jdk-headless python3 python3-pip wget

# Configure local DNS
cat <<EOF > /etc/hosts
127.0.0.1 localhost
192.168.56.10 master
192.168.56.11 worker
EOF

# Move to shared directory
cd /vagrant

# Download and extract Spark 4.1.2
if ! [ -f spark-4.1.2-bin-hadoop3.tgz ]; then
    echo "==> Downloading Spark 4.1.2..."
    wget https://downloads.apache.org/spark/spark-4.1.2/spark-4.1.2-bin-hadoop3.tgz
fi
if ! [ -d /usr/local/spark-4.1.2-bin-hadoop3 ]; then
    echo "==> Extracting Spark..."
    tar -C /usr/local -xzf spark-4.1.2-bin-hadoop3.tgz
fi

# Download and extract Hadoop 3.5.0
if ! [ -f hadoop-3.5.0.tar.gz ]; then
    echo "==> Downloading Hadoop 3.5.0..."
    wget https://downloads.apache.org/hadoop/common/hadoop-3.5.0/hadoop-3.5.0.tar.gz
fi
if ! [ -d /usr/local/hadoop-3.5.0 ]; then
    echo "==> Extracting Hadoop..."
    tar -C /usr/local -xzf hadoop-3.5.0.tar.gz
fi

# Change ownership to vagrant user
chown -R vagrant:vagrant /usr/local/hadoop-3.5.0
chown -R vagrant:vagrant /usr/local/spark-4.1.2-bin-hadoop3

# Resolve dynamic JAVA_PATH
JAVA_PATH=$(readlink -f /usr/bin/java | sed "s:bin/java::")

# Set environment variables globally
echo "==> Setting environment variables..."
cat <<EOF > /etc/profile.d/hadoop.sh
# Hadoop & Spark Vars
export JAVA_HOME=${JAVA_PATH}
export HADOOP_HOME=/usr/local/hadoop-3.5.0
export HADOOP_CONF_DIR=\${HADOOP_HOME}/etc/hadoop
export SPARK_HOME=/usr/local/spark-4.1.2-bin-hadoop3
export PATH=\${HADOOP_HOME}/bin:\${HADOOP_HOME}/sbin:\${SPARK_HOME}/bin:\$PATH

# PySpark & Jupyter Vars
export PYSPARK_PYTHON=/usr/bin/python3
export PYSPARK_DRIVER_PYTHON=jupyter
export PYSPARK_DRIVER_PYTHON_OPTS='notebook --ip=0.0.0.0 --port=8888 --no-browser'
EOF

# Make the profile script executable
chmod +x /etc/profile.d/hadoop.sh

# Add JAVA_HOME to hadoop-env.sh
if ! grep -q "JAVA_HOME=${JAVA_PATH}" /usr/local/hadoop-3.5.0/etc/hadoop/hadoop-env.sh; then
    echo "export JAVA_HOME=${JAVA_PATH}" >> /usr/local/hadoop-3.5.0/etc/hadoop/hadoop-env.sh
fi

HADOOP_CONF="/usr/local/hadoop-3.5.0/etc/hadoop"

# core-site.xml
cat <<EOF > $HADOOP_CONF/core-site.xml
<configuration>
    <property><name>fs.defaultFS</name><value>hdfs://master:9000</value></property>
    <property><name>hadoop.tmp.dir</name><value>/home/vagrant/hadoop-data</value></property>
</configuration>
EOF

# hdfs-site.xml
cat <<EOF > $HADOOP_CONF/hdfs-site.xml
<configuration>
    <property><name>dfs.replication</name><value>1</value></property>
    <property><name>dfs.namenode.http-address</name><value>0.0.0.0:9870</value></property>
</configuration>
EOF

# Dynamic YARN resource allocation
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
NM_MEM=$((TOTAL_MEM_MB - 2048))
TOTAL_CORES=$(nproc)
NM_CORES=$((TOTAL_CORES - 1))

# yarn-site.xml
cat <<EOF > $HADOOP_CONF/yarn-site.xml
<configuration>
    <property><name>yarn.resourcemanager.hostname</name><value>master</value></property>
    <property><name>yarn.resourcemanager.bind-host</name><value>0.0.0.0</value></property>
    <property><name>yarn.nodemanager.resource.memory-mb</name><value>${NM_MEM}</value></property>
    <property><name>yarn.nodemanager.resource.cpu-vcores</name><value>${NM_CORES}</value></property>
    <property><name>yarn.nodemanager.vmem-check-enabled</name><value>false</value></property>
    <property><name>yarn.nodemanager.pmem-check-enabled</name><value>false</value></property>
</configuration>
EOF

# Install Python libraries
echo "==> Installing Python packages..."
pip3 install jupyter pandas matplotlib seaborn pyspark==4.1.2 --break-system-packages --ignore-installed jsonschema

echo "==> Installing systemd units for Hadoop/YARN daemons..."

HADOOP_BIN="/usr/local/hadoop-3.5.0/bin"

# Environment for the units
cat <<EOF > /etc/hadoop-cluster.env
JAVA_HOME=${JAVA_PATH}
HADOOP_HOME=/usr/local/hadoop-3.5.0
HADOOP_CONF_DIR=/usr/local/hadoop-3.5.0/etc/hadoop
EOF

# Helper
write_unit() {  # $1=unit name  $2=description  $3=ExecStart command
    cat <<EOF > /etc/systemd/system/$1.service
[Unit]
Description=$2
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=vagrant
Group=vagrant
EnvironmentFile=/etc/hadoop-cluster.env
ExecStart=$3
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

if [ "$ROLE" == "master" ]; then
    su - vagrant -c "if [ ! -d /home/vagrant/hadoop-data/dfs/name ]; then $HADOOP_BIN/hdfs namenode -format -force; fi"

    write_unit hadoop-namenode        "Hadoop HDFS NameNode"         "$HADOOP_BIN/hdfs namenode"
    write_unit hadoop-resourcemanager "Hadoop YARN ResourceManager"  "$HADOOP_BIN/yarn resourcemanager"
    systemctl daemon-reload
    systemctl enable --now hadoop-namenode hadoop-resourcemanager
else
    write_unit hadoop-datanode    "Hadoop HDFS DataNode"     "$HADOOP_BIN/hdfs datanode"
    write_unit hadoop-nodemanager "Hadoop YARN NodeManager"  "$HADOOP_BIN/yarn nodemanager"
    systemctl daemon-reload
    systemctl enable --now hadoop-datanode hadoop-nodemanager
fi

echo "==> Provisioning complete for $ROLE!"