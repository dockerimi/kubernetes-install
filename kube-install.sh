#!/usr/bin/env bash

####################################################################################
####################################################################################
########## 根据情况修改
####################################################################################
# network
api_server_address="172.26.9.103"
service_cidr="10.1.0.0/16"
pod_network_cidr="10.2.0.0/16" # !!! 需要跟 flannel 中的 Network 设置一样 !!!
# set host
set_hosts () {
    cat > /etc/hosts << EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
172.26.9.103 k8s-node-1
172.26.9.102 k8s-node-2
172.26.9.104 k8s-node-3
EOF
# other
kubernetes_version="v1.18.3"
kuber_component_version="1.18.3-0"
flannel_version="v0.12.0-amd64"
ingress_controller_version="0.33.0"
}
####################################################################################
####################################################################################

show_log () {
    echo '============================================================================================'
    echo $1
    echo '============================================================================================'
}

download_images () {
    show_log '>>>>>>> pull image <<<<<<<'
    aliyun_registry=registry.aliyuncs.com/google_containers
    version=v1.18.3
    images=(`kubeadm config images list --kubernetes-version=$version|awk -F '/' '{print $2}'`)
    for image in ${images[@]} ; do
        show_log 'pull image >>> 'k8s.gcr.io/$image
        docker pull $aliyun_registry/$image
        docker tag $aliyun_registry/$image k8s.gcr.io/$image
        docker rmi -f $aliyun_registry/$image
    done

    show_log 'pull image >>> quay.io/coreos/flannel:'${flannel_version}
    docker pull quay.io/coreos/flannel:${flannel_version}
#    docker pull quay.azk8s.cn/coreos/flannel:${flannel_version}    quay.mirrors.ustc.edu.cn
#    docker tag quay.azk8s.cn/coreos/flannel:${flannel_version} quay.io/coreos/flannel:${flannel_version}
#    docker rmi -f quay.azk8s.cn/coreos/flannel:${flannel_version}

    show_log 'pull image >>> quay.io/kubernetes-ingress-controller/nginx-ingress-controller:'${ingress_controller_version}
    docker pull quay.io/kubernetes-ingress-controller/nginx-ingress-controller:${ingress_controller_version}
#    docker pull quay.azk8s.cn/kubernetes-ingress-controller/nginx-ingress-controller:${ingress_controller_version}
#    docker tag quay.azk8s.cn/kubernetes-ingress-controller/nginx-ingress-controller:${ingress_controller_version} quay.io/kubernetes-ingress-controller/nginx-ingress-controller:${ingress_controller_version}
#    docker rmi -f quay.azk8s.cn/kubernetes-ingress-controller/nginx-ingress-controller:${ingress_controller_version}
}

show_log $(cat /etc/redhat-release)

rm -rf /var/lib/cni
rm -rf /etc/cni/net.d
rm -rf /etc/kubernetes

show_log '换源...'
mv /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.backup
curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-7.repo
sed -i -e '/mirrors.cloud.aliyuncs.com/d' -e '/mirrors.aliyuncs.com/d' /etc/yum.repos.d/CentOS-Base.repo
yum install -y epel-release
yum makecache

show_log '安装基础工具...'
yum install -y yum-utils vim gcc make git wget unzip ntpdate htop nfs-utils net-tools tcpdump telnet telnet-server bash-completion

show_log '配置防火墙...'
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -F
systemctl enable firewalld
systemctl start firewalld
if [ $1 = 'master' ]; then
    show_log 'etcd port...'
    firewall-cmd --permanent --add-port=2379-2380/tcp
    show_log 'k8s api-server port...'
    firewall-cmd --permanent --add-port=6443/tcp
    show_log 'ingress lb port...'
    firewall-cmd --permanent --add-port=8443/tcp
    show_log 'kubelet port ...'
    firewall-cmd --permanent --add-port=10250/tcp
    show_log 'kube scheduler port...'
    firewall-cmd --permanent --add-port=10251/tcp
    show_log 'kube controller manager port...'
    firewall-cmd --permanent --add-port=10252/tcp
    show_log 'read only port...'
    firewall-cmd --permanent --add-port=10255/tcp
    show_log 'flannel port...'
    firewall-cmd --permanent --add-port=8472/udp
    show_log 'dns port...'
    firewall-cmd --permanent --add-port=53/udp
    firewall-cmd --permanent --add-port=53/tcp
    show_log 'public port...'
    firewall-cmd --permanent --add-port=80/tcp
    firewall-cmd --permanent --add-port=443/tcp
    firewall-cmd --permanent --add-port=443/udp
    firewall-cmd --permanent --add-port=30000-32767/tcp

    modprobe br_netfilter
elif [ $1 = 'node' ]; then
    show_log 'alert manager port ...'
    firewall-cmd --permanent --add-port=6783/tcp
    show_log 'ingress lb port...'
    firewall-cmd --permanent --add-port=8443/tcp
    show_log 'kubelet port ...'
    firewall-cmd --permanent --add-port=10250/tcp
    show_log 'read only port...'
    firewall-cmd --permanent --add-port=10255/tcp
    show_log 'flannel port...'
    firewall-cmd --permanent --add-port=8472/udp
    show_log 'dns port...'
    firewall-cmd --permanent --add-port=53/udp
    firewall-cmd --permanent --add-port=53/tcp
    show_log 'public port...'
    firewall-cmd --permanent --add-port=80/tcp
    firewall-cmd --permanent --add-port=443/tcp
    firewall-cmd --permanent --add-port=443/udp
    firewall-cmd --permanent --add-port=30000-32767/tcp
fi
firewall-cmd --add-masquerade --permanent
firewall-cmd --reload


show_log '关闭selinux'
sed -i 's/enforcing/disabled/' /etc/selinux/config
sed -i 's/SELINUX=permissive/SELINUX=disabled/' /etc/sysconfig/selinux
setenforce 0

show_log '关闭swap'
swapoff -a
sed -ri 's/.*swap.*/#&/' /etc/fstab

show_log '添加时间同步定时任务 保证集群内部统一...'
cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
ntpdate ntp1.aliyun.com
systemctl enable ntpdate
echo '*/30 * * * * /usr/sbin/ntpdate ntp1.aliyun.com > /dev/null 2>&1' > /tmp/cron.ntp.tmp && crontab /tmp/cron.ntp.tmp
systemctl start ntpdate

show_log '更改 limits...'
echo "* soft nofile 65536" >>   /etc/security/limits.conf
echo "* hard nofile 65536" >>   /etc/security/limits.conf
echo "* soft nproc 65536"  >>   /etc/security/limits.conf
echo "* hard nproc 65536"  >>   /etc/security/limits.conf
echo "* soft  memlock  unlimited"  >>   /etc/security/limits.conf
echo "* hard memlock unlimited"  >>     /etc/security/limits.conf

show_log '添加host...'
set_hosts

show_log '添加转发规则...'
cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward=1
net.ipv4.tcp_tw_recycle=0
vm.swappiness=0
vm.overcommit_memory=1
vm.panic_on_oom=0
fs.inotify.max_user_watches=89100
fs.file-max=52706963
fs.nr_open=52706963
net.ipv6.conf.all.disable_ipv6=1
net.netfilter.nf_conntrack_max=2310720
EOF

echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables
echo 1 > /proc/sys/net/bridge/bridge-nf-call-ip6tables

sysctl --system

show_log '>>>>>>> 安装Docker <<<<<<<'
# step 1: 安装必要的一些系统工具
yum install -y device-mapper-persistent-data lvm2
# Step 2: 添加软件源信息
yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
# Step 3: 更新并安装Docker-CE
yum makecache fast
yum -y install docker-ce-18.06.3.ce-3.el7
# Step 4: 开启Docker服务
systemctl enable docker && systemctl start docker
# Step 5: 添加镜像加速
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << EOF
{
"registry-mirrors": ["https://xxxxxxxx.mirror.aliyuncs.com"],
"exec-opts": ["native.cgroupdriver=systemd"]
}
EOF
# Step 6: enable && start
systemctl daemon-reload && systemctl restart docker

show_log '>>>>>>> 安装Kubernetes <<<<<<<'
cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF

yum install -y kubelet-${kuber_component_version} kubeadm-${kuber_component_version} kubectl-${kuber_component_version}

systemctl enable kubelet

# 添加kuctl补全
source /usr/share/bash-completion/bash_completion
echo "source <(kubectl completion bash)" >> ~/.bash_profile && source ~/.bash_profile

download_images

# Init master
if [ $1 = 'master' ]; then
    kubeadm init --apiserver-advertise-address=${api_server_address} --service-cidr=${service_cidr} --pod-network-cidr=${pod_network_cidr} --kubernetes-version=${kubernetes_version}

    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
fi