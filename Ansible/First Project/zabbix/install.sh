#!/bin/bash

# Немедленно завершить скрипт при возникновении ошибки
set -e

# ---------------------------- #
#         Конфигурация         #
# ---------------------------- #

# Переменные (Настройте их в соответствии с вашей средой)
DOMAIN="your_domain.com"                           # Ваш домен, например, zabbix.example.com
SSL_CERT_PATH="/etc/ssl/certs/your_cert.crt"       # Путь к вашему SSL-сертификату
SSL_KEY_PATH="/etc/ssl/private/your_key.key"      # Путь к вашему SSL-ключу
ZABBIX_VERSION="7.0"                               # Версия Zabbix
DB_NAME="zabbix"                                   # Имя базы данных Zabbix
DB_USER="zabbix"                                   # Имя пользователя базы данных Zabbix
DB_PASSWORD="StrongPasswordHere"                   # Пароль для пользователя базы данных Zabbix
POSTGRES_VERSION="15"                              # Версия PostgreSQL

# Проверка выполнения скрипта с правами root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт с правами root или с помощью sudo."
  exit 1
fi

# Function to display progress
function progress {
    local msg="$1"
    local count="$2"
    local total="$3"
    local percent=$(( count * 100 / total ))
    local bar_length=50
    local filled_length=$(( bar_length * count / total ))
    local bar=$(printf "%-${bar_length}s" "#" | sed "s/ /#/g")

    # Define colors
    local green="\033[0;32m"
    local red="\033[0;31m"
    local reset="\033[0m"

    # Create the progress bar
    local filled_bar="${green}${bar:0:filled_length}${reset}"
    local empty_bar="${red}${bar:filled_length:bar_length}${reset}"

    printf "\r%s |%s%s| %d%%" "$msg" "$filled_bar" "$empty_bar" "$percent"
}

# ---------------------------- #
#        Обновление Системы    #
# ---------------------------- #

echo "Обновление системных пакетов..."
apt update && apt upgrade -y
progress "Обновление системных пакетов..." 1 17

# ---------------------------- #
#      Установка Зависимостей  #
# ---------------------------- #

echo "Установка необходимых пакетов..."
apt install -y wget curl gnupg2 lsb-release ca-certificates software-properties-common
progress "Установка необходимых пакетов..." 2 17

# ---------------------------- #
#        Установка Nginx        #
# ---------------------------- #

echo "Установка Nginx..."
apt install -y nginx
progress "Установка Nginx..." 3 17

# ---------------------------- #
#    Отключение Default Site   #
# ---------------------------- #

echo "Отключение default сайта Nginx..."
rm -f /etc/nginx/sites-enabled/default
progress "Отключение default сайта Nginx..." 4 17

# ---------------------------- #
#      Установка PostgreSQL     #
# ---------------------------- #

echo "Установка PostgreSQL $POSTGRES_VERSION..."
# Добавление официального репозитория PostgreSQL
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | tee /usr/share/keyrings/postgresql.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" | tee /etc/apt/sources.list.d/pgdg.list

# Обновление списков пакетов после добавления репозитория PostgreSQL
apt update

# Установка PostgreSQL
apt install -y postgresql-$POSTGRES_VERSION postgresql-contrib
progress "Установка PostgreSQL $POSTGRES_VERSION..." 5 17

# ---------------------------- #
#        Установка TimescaleDB  #
# ---------------------------- #

echo "Установка TimescaleDB для PostgreSQL $POSTGRES_VERSION..."

# Добавление GPG-ключа TimescaleDB
mkdir -p /etc/apt/keyrings
wget -qO - https://packagecloud.io/timescale/timescaledb/gpgkey | gpg --dearmor | tee /etc/apt/keyrings/timescaledb.gpg > /dev/null

# Добавление репозитория TimescaleDB
echo "deb [signed-by=/etc/apt/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/debian/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/timescaledb.list

# Обновление списков пакетов после добавления репозитория TimescaleDB
apt update

# Установка TimescaleDB для PostgreSQL 15
apt install -y timescaledb-postgresql-$POSTGRES_VERSION

# Настройка TimescaleDB с использованием timescaledb-tune
echo "Настройка TimescaleDB..."
PG_CONFIG="/usr/lib/postgresql/$POSTGRES_VERSION/bin/pg_config"
timescaledb-tune --pg-config $PG_CONFIG --max-conns=125 --quiet --yes

# Перезапуск PostgreSQL для применения изменений
systemctl restart postgresql
progress "Установка TimescaleDB для PostgreSQL $POSTGRES_VERSION..." 6 17

# ---------------------------- #
#   Создание Базы Данных Zabbix#
# ---------------------------- #

echo "Настройка PostgreSQL для Zabbix..."

# Создание базы данных и пользователя с проверкой на существование
sudo -u postgres psql <<EOF
DO
\$do\$
BEGIN
   -- Создание базы данных, если она не существует
   IF NOT EXISTS (
      SELECT FROM pg_database
      WHERE datname = '$DB_NAME'
   ) THEN
      CREATE DATABASE $DB_NAME;
   END IF;
END
\$do\$;

-- Создание пользователя, если он не существует
DO
\$do\$
BEGIN
   IF NOT EXISTS (
      SELECT FROM pg_catalog.pg_roles
      WHERE rolname = '$DB_USER'
   ) THEN
      CREATE USER $DB_USER WITH ENCRYPTED PASSWORD '$DB_PASSWORD';
   END IF;
END
\$do\$;

-- Предоставление привилегий
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF

# Создание расширения TimescaleDB в базе данных Zabbix
echo "Создание расширения TimescaleDB в базе данных Zabbix..."
sudo -u postgres psql -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
progress "Настройка PostgreSQL для Zabbix..." 7 17

# ---------------------------- #
# Импорт Схемы и Данных Zabbix#
# ---------------------------- #

echo "Загрузка и импорт схемы базы данных Zabbix..."

# Переменные для загрузки Zabbix
ZABBIX_TAR="zabbix-$ZABBIX_VERSION.tar.gz"
ZABBIX_URL="https://cdn.zabbix.com/zabbix/sources/stable/$ZABBIX_VERSION/$ZABBIX_TAR"

# Загрузка архива Zabbix
wget $ZABBIX_URL

# Распаковка архива
tar -xzf $ZABBIX_TAR

# Переход в директорию с файлами базы данных
cd zabbix-$ZABBIX_VERSION/database/postgresql

# Импорт схемы, изображений и данных
sudo -u postgres psql -d $DB_NAME -U $DB_USER -f schema.sql
sudo -u postgres psql -d $DB_NAME -U $DB_USER -f images.sql
sudo -u postgres psql -d $DB_NAME -U $DB_USER -f data.sql

# Возврат в корневую директорию
cd ../../..
progress "Загрузка и импорт схемы базы данных Zabbix..." 8 17

# ---------------------------- #
#     Добавление Репозитория Zabbix #
# ---------------------------- #

echo "Добавление репозитория Zabbix..."

# Переменные для репозитория Zabbix
ZABBIX_REPO_DEB="zabbix-release_$ZABBIX_VERSION-1+debian12_all.deb"
ZABBIX_REPO_URL="https://repo.zabbix.com/zabbix/$ZABBIX_VERSION/debian/pool/main/z/zabbix-release/$ZABBIX_REPO_DEB"

# Загрузка пакета репозитория Zabbix
wget $ZABBIX_REPO_URL

# Установка пакета репозитория
dpkg -i $ZABBIX_REPO_DEB

# Обновление списков пакетов после добавления репозитория Zabbix
apt update

# Удаление пакета репозитория после установки
rm -f $ZABBIX_REPO_DEB
progress "Добавление репозитория Zabbix..." 9 17

# ---------------------------- #
# Установка Zabbix Server и Frontend #
# ---------------------------- #

echo "Установка Zabbix server, frontend и agent..."

apt install -y zabbix-server-pgsql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts zabbix-agent
progress "Установка Zabbix server, frontend и agent..." 10 17

# ---------------------------- #
#   Настройка Zabbix Server     #
# ---------------------------- #

echo "Настройка Zabbix server для использования PostgreSQL..."

# Обновление конфигурационного файла Zabbix server с паролем базы данных
sed -i "s/^# DBPassword=/DBPassword=$DB_PASSWORD/" /etc/zabbix/zabbix_server.conf
progress "Настройка Zabbix server для использования PostgreSQL..." 11 17

# ---------------------------- #
# Установка PHP и Модулей     #
# ---------------------------- #

echo "Установка PHP и необходимых модулей..."

apt install -y php-fpm php-pgsql php-xml php-bcmath php-gd
progress "Установка PHP и необходимых модулей..." 12 17

# ---------------------------- #
#   Настройка PHP для Zabbix    #
# ---------------------------- #

echo "Настройка PHP для фронтенда Zabbix..."

PHP_CONF_DIR="/etc/php"
PHP_FPM_CONF="$PHP_CONF_DIR/$PHP_VERSION/fpm/php.ini"

# Проверка существования файла конфигурации PHP
if [ ! -f "$PHP_FPM_CONF" ]; then
  echo "Файл конфигурации PHP не найден: $PHP_FPM_CONF"
  exit 1
fi

# Изменение настроек PHP
sed -i "s/^post_max_size = .*/post_max_size = 16M/" $PHP_FPM_CONF
sed -i "s/^max_execution_time = .*/max_execution_time = 300/" $PHP_FPM_CONF
sed -i "s/^memory_limit = .*/memory_limit = 128M/" $PHP_FPM_CONF
sed -i "s/^max_input_time = .*/max_input_time = 300/" $PHP_FPM_CONF

# Перезапуск PHP-FPM для применения изменений
systemctl restart php$PHP_VERSION-fpm
progress "Настройка PHP для фронтенда Zabbix..." 13 17

# ---------------------------- #
#    Настройка Nginx для Zabbix #
# ---------------------------- #

echo "Настройка Nginx для фронтенда Zabbix..."

# Создание конфигурационного файла Nginx для Zabbix
cat > /etc/nginx/sites-available/zabbix.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate $SSL_CERT_PATH;
    ssl_certificate_key $SSL_KEY_PATH;

    root /usr/share/zabbix;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php$PHP_VERSION-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# Включение сайта Zabbix в Nginx
ln -sf /etc/nginx/sites-available/zabbix.conf /etc/nginx/sites-enabled/

# Проверка конфигурации Nginx
echo "Проверка конфигурации Nginx..."
nginx -t

# Перезапуск Nginx для применения изменений
systemctl restart nginx
progress "Настройка Nginx для фронтенда Zabbix..." 14 17

# ---------------------------- #
#   Запуск и Включение Сервисов #
# ---------------------------- #

echo "Запуск и включение Zabbix server, agent и PHP-FPM..."

systemctl restart zabbix-server zabbix-agent php$PHP_VERSION-fpm
systemctl enable zabbix-server zabbix-agent php$PHP_VERSION-fpm
progress "Запуск и включение Zabbix server, agent и PHP-FPM..." 15 17

# ---------------------------- #
#     Настройка Брандмауэра   #
# ---------------------------- #

echo "Настройка брандмауэра UFW..."

apt install -y ufw

# Разрешение SSH и Nginx Full
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw allow 10051/tcp

# Включение UFW без подтверждения
ufw --force enable
progress "Настройка брандмауэра UFW..." 16 17

# ---------------------------- #
#         Завершение          #
# ---------------------------- #

echo "Установка Zabbix завершена успешно."
echo "Пожалуйста, перейдите по адресу https://$DOMAIN в вашем веб-браузере для завершения настройки фронтенда."
echo "Используйте следующие данные для подключения к базе данных при настройке:"
echo " - Тип базы данных: PostgreSQL"
echo " - Имя базы данных: $DB_NAME"
echo " - Пользователь: $DB_USER"
echo " - Пароль: $DB_PASSWORD"
echo " - Сервер: localhost"

# ---------------------------- #
#         Очистка             #
# ---------------------------- #

echo "Очистка временных файлов..."

rm -rf zabbix-$ZABBIX_VERSION.tar.gz zabbix-$ZABBIX_VERSION
progress "Очистка временных файлов..." 17 17
echo "Скрипт развертывания завершен успешно."
