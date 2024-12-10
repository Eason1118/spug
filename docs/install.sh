#!/bin/bash
# Copyright: (c) OpenSpug Organization. https://github.com/openspug/spug
# Copyright: (c) <spug.dev@gmail.com>
# Released under the AGPL-3.0 License.

set -e

# 显示Spug标志
function spug_banner() {
cat << "EOF"

 ####  #####  #    #  #### 
#      #    # #    # #    #
 ####  #    # #    # #     
     # #####  #    # #  ###
#    # #      #    # #    #
 ####  #       ####   #### 

EOF
}

# 系统依赖安装
function init_system_lib() {
    source /etc/os-release
    local packages
    case $ID in
        centos|fedora|rhel)
            packages="git mariadb-server mariadb-devel python3-devel gcc openldap-devel redis nginx supervisor python36"
            yum install -y epel-release $packages
            sed -i 's/ default_server//g' /etc/nginx/nginx.conf
            MYSQL_CONF="/etc/my.cnf.d/spug.cnf"
            SUPERVISOR_CONF="/etc/supervisord.d/spug.ini"
            REDIS_SRV="redis"
            SUPERVISOR_SRV="supervisord"
            ;;
        debian|ubuntu|devuan)
            packages="git mariadb-server libmariadbd-dev python3-dev python3-venv libsasl2-dev libldap2-dev redis-server nginx supervisor"
            apt update && apt install -y $packages
            rm -f /etc/nginx/sites-enabled/default
            MYSQL_CONF="/etc/mysql/conf.d/spug.cnf"
            SUPERVISOR_CONF="/etc/supervisor/conf.d/spug.conf"
            REDIS_SRV="redis-server"
            SUPERVISOR_SRV="supervisor"
            ;;
        *)
            echo "不支持的操作系统: $ID"
            exit 1
            ;;
    esac
}

# 安装Spug
function install_spug() {
    echo "开始安装Spug..."
    mkdir -p /data
    cd /data
    git clone --depth=1 https://gitee.com/openspug/spug.git
    curl -o /tmp/web_latest.tar.gz https://spug.dev/installer/web_latest.tar.gz
    tar xf /tmp/web_latest.tar.gz -C spug/spug_web/
    cd spug/spug_api
    python3 -m venv venv
    source venv/bin/activate

    pip install -i https://pypi.doubanio.com/simple/ wheel gunicorn mysqlclient -r requirements.txt
}

# 配置Spug
function setup_conf() {
    echo "开始配置Spug配置..."

    # MySQL 配置
    cat << EOF > $MYSQL_CONF
[mysqld]
bind-address=127.0.0.1
EOF

    # Spug 配置
    cat << EOF > spug/overrides.py
DEBUG = False
ALLOWED_HOSTS = ['127.0.0.1']

DATABASES = {
    'default': {
        'ATOMIC_REQUESTS': True,
        'ENGINE': 'django.db.backends.mysql',
        'NAME': 'spug',
        'USER': 'spug',
        'PASSWORD': 'spug.dev',
        'HOST': '127.0.0.1',
        'OPTIONS': {
            'charset': 'utf8mb4',
            'sql_mode': 'STRICT_TRANS_TABLES',
        }
    }
}
EOF

    # Supervisor 配置
    cat << EOF > $SUPERVISOR_CONF
[program:spug-api]
command = bash /data/spug/spug_api/tools/start-api.sh
autostart = true
stdout_logfile = /data/spug/spug_api/logs/api.log
redirect_stderr = true

[program:spug-ws]
command = bash /data/spug/spug_api/tools/start-ws.sh
autostart = true
stdout_logfile = /data/spug/spug_api/logs/ws.log
redirect_stderr = true

[program:spug-worker]
command = bash /data/spug/spug_api/tools/start-worker.sh
autostart = true
stdout_logfile = /data/spug/spug_api/logs/worker.log
redirect_stderr = true

[program:spug-monitor]
command = bash /data/spug/spug_api/tools/start-monitor.sh
autostart = true
stdout_logfile = /data/spug/spug_api/logs/monitor.log
redirect_stderr = true

[program:spug-scheduler]
command = bash /data/spug/spug_api/tools/start-scheduler.sh
autostart = true
stdout_logfile = /data/spug/spug_api/logs/scheduler.log
redirect_stderr = true
EOF

    # Nginx 配置
    cat << EOF > /etc/nginx/conf.d/spug.conf
server {
    listen 80 default_server;
    root /data/spug/spug_web/build/;

    location ^~ /api/ {
        rewrite ^/api(.*) \$1 break;
        proxy_pass http://127.0.0.1:9001;
        proxy_redirect off;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location ^~ /api/ws/ {
        rewrite ^/api(.*) \$1 break;
        proxy_pass http://127.0.0.1:9002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header X-Real-IP \$remote_addr;
    }

    error_page 404 /index.html;
}
EOF

    systemctl enable --now mariadb $REDIS_SRV nginx $SUPERVISOR_SRV

    mysql -e "CREATE DATABASE spug DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "GRANT ALL ON spug.* TO spug@127.0.0.1 IDENTIFIED BY 'spug.dev'; FLUSH PRIVILEGES;"

    python manage.py initdb
    python manage.py useradd -u admin -p spug.dev -s -n 管理员

    systemctl restart $SUPERVISOR_SRV nginx
}

spug_banner
init_system_lib
install_spug
setup_conf

echo -e "\n\033[33m安全警告：请根据文档加强数据库和Redis的安全性！\033[0m"
echo -e "\033[32m安装成功！\033[0m"
echo "管理员账户：admin  密码：spug.dev"
echo "数据库用户：spug   密码：spug.dev"
