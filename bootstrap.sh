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

# Safe download helper
download_archive() {
    local url="$1"
    local filename="$2"
    if [ ! -f "/vagrant/${filename}" ]; then
        echo "==> Downloading ${filename}..."
        wget -q -c "$url" -O "/vagrant/${filename}.${ROLE}.tmp" && \
        mv -n "/vagrant/${filename}.${ROLE}.tmp" "/vagrant/${filename}" 2>/dev/null || true
        rm -f "/vagrant/${filename}.${ROLE}.tmp"
    fi
}

# --- Hadoop Setup (Both Nodes) ---
download_archive "https://downloads.apache.org/hadoop/common/hadoop-3.5.0/hadoop-3.5.0.tar.gz" "hadoop-3.5.0.tar.gz"

if [ ! -d /usr/local/hadoop-3.5.0 ]; then
    echo "==> Extracting Hadoop..."
    tar -C /usr/local -xzf /vagrant/hadoop-3.5.0.tar.gz
    chown -R vagrant:vagrant /usr/local/hadoop-3.5.0
fi

# --- Spark Setup (Master Only) ---
if [ "$ROLE" == "master" ]; then
    download_archive "https://downloads.apache.org/spark/spark-4.1.2/spark-4.1.2-bin-hadoop3.tgz" "spark-4.1.2-bin-hadoop3.tgz"

    if [ ! -d /usr/local/spark-4.1.2-bin-hadoop3 ]; then
        echo "==> Extracting Spark on master..."
        tar -C /usr/local -xzf /vagrant/spark-4.1.2-bin-hadoop3.tgz
        chown -R vagrant:vagrant /usr/local/spark-4.1.2-bin-hadoop3
    fi
fi

# Resolve dynamic JAVA_PATH
JAVA_PATH=$(readlink -f /usr/bin/java | sed "s:bin/java::")

# Set global environment variables
echo "==> Configuring environment variables..."
cat <<EOF > /etc/profile.d/hadoop.sh
export JAVA_HOME=${JAVA_PATH}
export HADOOP_HOME=/usr/local/hadoop-3.5.0
export HADOOP_CONF_DIR=\${HADOOP_HOME}/etc/hadoop
export PATH=\${HADOOP_HOME}/bin:\${HADOOP_HOME}/sbin:\$PATH
export PYSPARK_PYTHON=/usr/bin/python3
EOF

if [ "$ROLE" == "master" ]; then
    PY4J_ZIP=$(ls /usr/local/spark-4.1.2-bin-hadoop3/python/lib/py4j-*-src.zip 2>/dev/null | head -n 1)
    cat <<EOF >> /etc/profile.d/hadoop.sh
export SPARK_HOME=/usr/local/spark-4.1.2-bin-hadoop3
export PATH=\${SPARK_HOME}/bin:\$PATH
export PYTHONPATH=\${SPARK_HOME}/python:${PY4J_ZIP}:\$PYTHONPATH
export PYSPARK_DRIVER_PYTHON=jupyter
export PYSPARK_DRIVER_PYTHON_OPTS='notebook --ip=0.0.0.0 --port=8888 --no-browser'
EOF
fi

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

# yarn-site.xml (Split by role)
if [ "$ROLE" == "master" ]; then
cat <<EOF > $HADOOP_CONF/yarn-site.xml
<configuration>
    <property><name>yarn.resourcemanager.hostname</name><value>master</value></property>
    <property><name>yarn.resourcemanager.bind-host</name><value>0.0.0.0</value></property>
</configuration>
EOF
else
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
NM_MEM=$((TOTAL_MEM_MB - 2048))
TOTAL_CORES=$(nproc)
NM_CORES=$((TOTAL_CORES - 1))

cat <<EOF > $HADOOP_CONF/yarn-site.xml
<configuration>
    <property><name>yarn.resourcemanager.hostname</name><value>master</value></property>
    <property><name>yarn.nodemanager.resource.memory-mb</name><value>${NM_MEM}</value></property>
    <property><name>yarn.nodemanager.resource.cpu-vcores</name><value>${NM_CORES}</value></property>
    <property><name>yarn.nodemanager.vmem-check-enabled</name><value>false</value></property>
    <property><name>yarn.nodemanager.pmem-check-enabled</name><value>false</value></property>
</configuration>
EOF
fi

# Python packages
echo "==> Installing Python packages..."
pip3 install pandas --break-system-packages

if [ "$ROLE" == "master" ]; then
    echo "==> Installing Jupyter and visualization libraries on master..."
    pip3 install jupyter matplotlib seaborn --break-system-packages
fi

echo "==> Installing systemd units for Hadoop/YARN daemons..."

HADOOP_BIN="/usr/local/hadoop-3.5.0/bin"

cat <<EOF > /etc/hadoop-cluster.env
JAVA_HOME=${JAVA_PATH}
HADOOP_HOME=/usr/local/hadoop-3.5.0
HADOOP_CONF_DIR=/usr/local/hadoop-3.5.0/etc/hadoop
EOF

write_unit() {
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
